package main

import (
	"testing"
	"time"
)

// The README says that the server keeps the address of a failed request for at most 15
// minutes (the window), also when no request follows.
func TestLimiterForgets(t *testing.T) {
	l := newLimiter(1, 50*time.Millisecond)
	l.fail("192.0.2.1")
	if !l.blocked("192.0.2.1") {
		t.Fatal("not blocked")
	}
	for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		l.mu.Lock()
		n := len(l.hits)
		l.mu.Unlock()
		if n == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("address kept after the window")
		}
	}
}
