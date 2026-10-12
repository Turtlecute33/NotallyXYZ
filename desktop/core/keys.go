package core

import (
	"crypto/rand"
	"encoding/base64"

	"notallyxyz-server/seal"
)

// Keys are the sync key and the keys derived from it (PROTOCOL.md §1–3).
type Keys struct {
	Raw []byte
	seal.Keys
}

func NewKeys(raw []byte) Keys { return Keys{Raw: raw, Keys: seal.DeriveKeys(raw)} }

func GenerateKeys() Keys {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		panic(err)
	}
	return NewKeys(raw)
}

// ParseKeys reads the display form of a sync key and checks its checksum.
func ParseKeys(text string) (Keys, error) {
	raw, err := seal.ParseKey(text)
	if err != nil {
		return Keys{}, err
	}
	return NewKeys(raw), nil
}

func (k Keys) Display() string                { return seal.FormatKey(k.Raw) }
func (k Keys) Bearer() string                 { return base64.RawURLEncoding.EncodeToString(k.AuthToken) }
func (k Keys) LabelID(value string) string    { return seal.LabelID(k.IDKey, value) }
func (k Keys) BlobID(localName string) string { return seal.BlobID(k.IDKey, localName) }

// Seal encrypts a record or blob with a fresh salt.
func (k Keys) Seal(kind, id string, m []byte) []byte {
	salt := make([]byte, seal.SaltSize)
	if _, err := rand.Read(salt); err != nil {
		panic(err)
	}
	return seal.Seal(k.EncKey, salt, seal.AD(kind, id), m)
}

func (k Keys) Open(kind, id string, sealed []byte) ([]byte, error) {
	return seal.Open(k.EncKey, seal.AD(kind, id), sealed)
}
