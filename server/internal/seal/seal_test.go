package seal

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"os"
	"testing"
)

func TestPadme(t *testing.T) {
	cases := map[uint64]uint64{8: 8, 256: 256, 257: 272, 1000: 1024, 65536: 65536, 70000: 71680, 1 << 20: 1 << 20}
	for in, want := range cases {
		if got := Padme(in); got != want {
			t.Errorf("Padme(%d) = %d, want %d", in, got, want)
		}
	}
}

func TestKeyRoundTrip(t *testing.T) {
	k := make([]byte, 32)
	rand.Read(k)
	s := FormatKey(k)
	if len(s) != 56+13 {
		t.Fatalf("len %d", len(s))
	}
	got, err := ParseKey(" " + bytes.NewBufferString(s).String() + "\n")
	if err != nil || !bytes.Equal(got, k) {
		t.Fatalf("round trip: %v", err)
	}
	bad := []byte(s)
	if bad[0] == 'A' {
		bad[0] = 'B'
	} else {
		bad[0] = 'A'
	}
	if _, err := ParseKey(string(bad)); err == nil {
		t.Fatal("typo not detected")
	}
}

func TestSealRoundTrip(t *testing.T) {
	enc := make([]byte, 32)
	rand.Read(enc)
	for _, n := range []int{0, 1, 247, 248, 249, 65528, 65529, 65536 * 3, 200001} {
		m := make([]byte, n)
		rand.Read(m)
		salt := make([]byte, 32)
		rand.Read(salt)
		ad := AD("blob", "00112233445566778899aabbccddeeff")
		s := Seal(enc, salt, ad, m)
		if len(s) != SealedSize(n) {
			t.Fatalf("n=%d size %d want %d", n, len(s), SealedSize(n))
		}
		got, err := Open(enc, ad, s)
		if err != nil || !bytes.Equal(got, m) {
			t.Fatalf("n=%d open: %v", n, err)
		}
		if _, err := Open(enc, AD("note", "00112233445566778899aabbccddeeff"), s); err == nil {
			t.Fatal("wrong ad accepted")
		}
		if len(s) > 1+32+ChunkSize+TagSize {
			if _, err := Open(enc, ad, s[:1+32+ChunkSize+TagSize]); err == nil {
				t.Fatal("truncation accepted")
			}
		}
	}
}

// TestVectors checks testvectors.json, which the Kotlin and Swift tests also use.
func TestVectors(t *testing.T) {
	raw, err := os.ReadFile("../../testvectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var v Vectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	want := Generate()
	gotJSON, _ := json.Marshal(v)
	wantJSON, _ := json.Marshal(want)
	if !bytes.Equal(gotJSON, wantJSON) {
		t.Fatal("testvectors.json is out of date: run `go run ./cmd/vectors > testvectors.json`")
	}
	for _, s := range v.Seal {
		m, err := Open(hexd(v.EncKey), AD(s.Kind, s.ID), hexd(s.Sealed))
		if err != nil || !bytes.Equal(m, hexd(s.Plain)) {
			t.Fatalf("vector %s: %v", s.Name, err)
		}
	}
}
