// Package seal is the reference implementation of the client crypto in PROTOCOL.md.
// The server does not use it; it exists for tests and test vectors.
package seal

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base32"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"math/bits"
	"strings"
)

const (
	Version   = 0x01
	SaltSize  = 32
	ChunkSize = 65536
	TagSize   = 16
	MinPadded = 256
)

var crockford = base32.NewEncoding("0123456789ABCDEFGHJKMNPQRSTVWXYZ").WithPadding(base32.NoPadding)

var ErrInvalid = errors.New("invalid sealed data")

// Keys are derived from the 32-byte sync key.
type Keys struct {
	AuthToken []byte
	EncKey    []byte
	IDKey     []byte
}

func derive(ikm, salt []byte, info string) []byte {
	k, err := hkdf.Key(sha256.New, ikm, salt, info, 32)
	if err != nil {
		panic(err)
	}
	return k
}

func DeriveKeys(k []byte) Keys {
	return Keys{
		AuthToken: derive(k, nil, "notallyxyz/v1/auth"),
		EncKey:    derive(k, nil, "notallyxyz/v1/enc"),
		IDKey:     derive(k, nil, "notallyxyz/v1/id"),
	}
}

func checksum(k []byte) []byte {
	sum := sha256.Sum256(append([]byte("notallyxyz/v1/key-check"), k...))
	return sum[:3]
}

// FormatKey returns the display form of a 32-byte sync key.
func FormatKey(k []byte) string {
	enc := crockford.EncodeToString(append(append([]byte{}, k...), checksum(k)...))
	var groups []string
	for i := 0; i < len(enc); i += 4 {
		groups = append(groups, enc[i:i+4])
	}
	return strings.Join(groups, "-")
}

// ParseKey reverses FormatKey and verifies the checksum.
func ParseKey(s string) ([]byte, error) {
	s = strings.ToUpper(strings.NewReplacer(" ", "", "-", "", "\n", "", "\t", "").Replace(s))
	s = strings.NewReplacer("O", "0", "I", "1", "L", "1").Replace(s)
	if len(s) != 56 {
		return nil, errors.New("wrong length")
	}
	raw, err := crockford.DecodeString(s)
	if err != nil || len(raw) != 35 {
		return nil, errors.New("invalid characters")
	}
	if !hmac.Equal(raw[32:], checksum(raw[:32])) {
		return nil, errors.New("checksum mismatch")
	}
	return raw[:32], nil
}

func hmacID(idKey []byte, msg string) string {
	m := hmac.New(sha256.New, idKey)
	m.Write([]byte(msg))
	return hex.EncodeToString(m.Sum(nil)[:16])
}

func LabelID(idKey []byte, value string) string    { return hmacID(idKey, "label:"+value) }
func BlobID(idKey []byte, localName string) string { return hmacID(idKey, "blob:"+localName) }

func Padme(l uint64) uint64 {
	if l < 2 {
		return l
	}
	e := uint64(63 - bits.LeadingZeros64(l))
	s := uint64(63-bits.LeadingZeros64(e)) + 1
	z := e - s
	mask := uint64(1)<<z - 1
	return (l + mask) &^ mask
}

func PaddedSize(n int) int {
	t := int(Padme(uint64(8 + n)))
	if t < MinPadded {
		t = MinPadded
	}
	return t
}

func SealedSize(n int) int {
	t := PaddedSize(n)
	return 1 + SaltSize + t + TagSize*((t+ChunkSize-1)/ChunkSize)
}

func AD(kind, id string) []byte { return []byte("notallyxyz/v1|" + kind + "|" + id) }

func nonce(i int, last bool) []byte {
	n := make([]byte, 12)
	binary.BigEndian.PutUint32(n[7:11], uint32(i))
	if last {
		n[11] = 1
	}
	return n
}

func aead(encKey, salt []byte) cipher.AEAD {
	block, err := aes.NewCipher(derive(encKey, salt, "notallyxyz/v1/seal"))
	if err != nil {
		panic(err)
	}
	g, err := cipher.NewGCM(block)
	if err != nil {
		panic(err)
	}
	return g
}

// Seal encrypts m with a given salt (tests use a fixed salt, real code a random one).
func Seal(encKey, salt, ad, m []byte) []byte {
	t := PaddedSize(len(m))
	p := make([]byte, t)
	binary.BigEndian.PutUint64(p, uint64(len(m)))
	copy(p[8:], m)
	g := aead(encKey, salt)
	out := append([]byte{Version}, salt...)
	n := (t + ChunkSize - 1) / ChunkSize
	for i := 0; i < n; i++ {
		end := min((i+1)*ChunkSize, t)
		out = g.Seal(out, nonce(i, i == n-1), p[i*ChunkSize:end], ad)
	}
	return out
}

func Open(encKey, ad, sealed []byte) ([]byte, error) {
	if len(sealed) < 1+SaltSize+TagSize+1 || sealed[0] != Version {
		return nil, ErrInvalid
	}
	g := aead(encKey, sealed[1:1+SaltSize])
	body := sealed[1+SaltSize:]
	var p []byte
	for i := 0; len(body) > 0; i++ {
		size := min(len(body), ChunkSize+TagSize)
		last := len(body) == size
		if size <= TagSize {
			return nil, ErrInvalid
		}
		plain, err := g.Open(nil, nonce(i, last), body[:size], ad)
		if err != nil {
			return nil, ErrInvalid
		}
		p = append(p, plain...)
		body = body[size:]
	}
	if len(p) < 8 {
		return nil, ErrInvalid
	}
	n := binary.BigEndian.Uint64(p)
	if n > uint64(len(p)-8) || !bytes.Equal(p[8+n:], make([]byte, len(p)-8-int(n))) {
		return nil, ErrInvalid
	}
	return p[8 : 8+n], nil
}
