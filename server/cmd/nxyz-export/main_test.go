package main

import (
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

// Go sends the Authorization header again on a redirect to the same host, also from https to
// http. The tool must not follow redirects.
func TestNoRedirect(t *testing.T) {
	var leaked atomic.Bool
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		leaked.Store(r.Header.Get("Authorization") != "")
	}))
	defer target.Close()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+r.URL.Path, http.StatusFound)
	}))
	defer srv.Close()
	if _, err := (client{base: srv.URL, token: "secret"}).get("/account"); err == nil {
		t.Fatal("redirect followed")
	}
	if leaked.Load() {
		t.Fatal("token sent to the redirect target")
	}
}
