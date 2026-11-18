package main

import "testing"

// A value in MiB that does not fit in bytes is an error, not a negative or small limit.
func TestEnvMiBOverflow(t *testing.T) {
	for _, v := range []string{"8796093022208", "17592186044417"} {
		t.Setenv("MAX_BLOB_MB", v)
		if n, err := envMiB("MAX_BLOB_MB", 100); err == nil {
			t.Errorf("%s MiB: %d bytes, no error", v, n)
		}
	}
	t.Setenv("MAX_BLOB_MB", "8796093022207")
	if n, err := envMiB("MAX_BLOB_MB", 100); err != nil || n != 8796093022207<<20 {
		t.Errorf("largest value: %d %v", n, err)
	}
}
