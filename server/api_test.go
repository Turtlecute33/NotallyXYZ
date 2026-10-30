package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const invite = "test-invite-token-0123456789"

func newTestServer(t *testing.T, mutate func(*config)) *httptest.Server {
	t.Helper()
	dir := t.TempDir()
	cfg := config{dataDir: dir, signupToken: invite, maxBlobBytes: 1 << 20}
	if mutate != nil {
		mutate(&cfg)
	}
	store, err := openStore(filepath.Join(dir, "db"), filepath.Join(dir, "blobs"))
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(newAPI(cfg, store).routes())
	t.Cleanup(func() { srv.Close(); store.Close() })
	return srv
}

func newToken() string {
	b := make([]byte, 32)
	rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

func do(t *testing.T, srv *httptest.Server, method, path, token string, body any) (int, map[string]any) {
	t.Helper()
	var r io.Reader
	switch b := body.(type) {
	case nil:
	case []byte:
		r = bytes.NewReader(b)
	default:
		raw, _ := json.Marshal(b)
		r = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, srv.URL+path, r)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	if out == nil {
		out = map[string]any{"raw": string(raw)}
	}
	return resp.StatusCode, out
}

func signup(t *testing.T, srv *httptest.Server) string {
	tok := newToken()
	if code, _ := do(t, srv, "POST", "/v1/account", tok, map[string]string{"invite": invite}); code != 201 {
		t.Fatalf("signup: %d", code)
	}
	return tok
}

func TestAccount(t *testing.T) {
	srv := newTestServer(t, func(c *config) { c.maxAccounts = 1 })
	if code, _ := do(t, srv, "GET", "/v1/health", "", nil); code != 200 {
		t.Fatal("health")
	}
	tok := newToken()
	if code, _ := do(t, srv, "POST", "/v1/account", tok, map[string]string{"invite": "wrong-wrong-wrong-wrong"}); code != 403 {
		t.Fatalf("wrong invite: %d", code)
	}
	if code, _ := do(t, srv, "GET", "/v1/account", tok, nil); code != 401 {
		t.Fatalf("unknown token: %d", code)
	}
	if code, _ := do(t, srv, "POST", "/v1/account", tok, map[string]string{"invite": invite}); code != 201 {
		t.Fatalf("create: %d", code)
	}
	if code, _ := do(t, srv, "POST", "/v1/account", tok, map[string]string{"invite": ""}); code != 200 {
		t.Fatalf("exists: %d", code)
	}
	if code, body := do(t, srv, "POST", "/v1/account", newToken(), map[string]string{"invite": strings.Repeat("x", 100<<10)}); code != 413 || body["error"] != "too_large" {
		t.Fatalf("large body: %d %v", code, body)
	}
	if code, body := do(t, srv, "POST", "/v1/account", newToken(), map[string]string{"invite": invite}); code != 403 || body["error"] != "accounts_limit" {
		t.Fatalf("limit: %d %v", code, body)
	}
	code, info := do(t, srv, "GET", "/v1/account", tok, nil)
	if code != 200 || info["seq"].(float64) != 0 || info["maxBlobBytes"].(float64) != 1<<20 {
		t.Fatalf("info: %d %v", code, info)
	}
	if code, _ := do(t, srv, "DELETE", "/v1/account", tok, nil); code != 204 {
		t.Fatalf("delete: %d", code)
	}
	if code, _ := do(t, srv, "GET", "/v1/account", tok, nil); code != 401 {
		t.Fatalf("after delete: %d", code)
	}
}

func TestSignupDisabled(t *testing.T) {
	srv := newTestServer(t, func(c *config) { c.signupToken = "" })
	code, body := do(t, srv, "POST", "/v1/account", newToken(), map[string]string{"invite": ""})
	if code != 403 || body["error"] != "signup_disabled" {
		t.Fatalf("%d %v", code, body)
	}
}

func TestRateLimit(t *testing.T) {
	srv := newTestServer(t, nil)
	var code int
	for i := 0; i < 31; i++ {
		code, _ = do(t, srv, "GET", "/v1/account", newToken(), nil)
	}
	if code != 429 {
		t.Fatalf("want 429, got %d", code)
	}
}

const idA = "0123456789abcdef0123456789abcdef"
const idB = "fedcba9876543210fedcba9876543210"

func changesOf(body map[string]any) []map[string]any {
	var out []map[string]any
	for _, c := range body["changes"].([]any) {
		out = append(out, c.(map[string]any))
	}
	return out
}

func TestChanges(t *testing.T) {
	srv := newTestServer(t, nil)
	tok := signup(t, srv)
	push := func(changes ...map[string]any) []any {
		code, body := do(t, srv, "POST", "/v1/changes", tok, map[string]any{"changes": changes})
		if code != 200 {
			t.Fatalf("push: %d %v", code, body)
		}
		return body["results"].([]any)
	}
	data := []byte("ciphertext")
	res := push(map[string]any{"kind": "note", "id": idA, "base": 0, "data": data},
		map[string]any{"kind": "label", "id": idB, "base": 0, "data": data})
	if res[0].(map[string]any)["seq"].(float64) != 1 || res[1].(map[string]any)["seq"].(float64) != 2 {
		t.Fatalf("seqs: %v", res)
	}
	// Stale base is a conflict and is not written.
	res = push(map[string]any{"kind": "note", "id": idA, "base": 0, "data": []byte("other")})
	if r := res[0].(map[string]any); r["conflict"] != true || r["seq"].(float64) != 1 {
		t.Fatalf("conflict: %v", res)
	}
	// A tombstone carries sealed data; the server keeps it and returns it.
	res = push(map[string]any{"kind": "note", "id": idA, "base": 1, "deleted": true, "data": []byte("sealed tombstone")})
	if res[0].(map[string]any)["seq"].(float64) != 3 {
		t.Fatalf("delete: %v", res)
	}
	_, body := do(t, srv, "GET", "/v1/changes?since=0", tok, nil)
	ch := changesOf(body)
	if len(ch) != 2 || ch[0]["id"] != idB || ch[1]["id"] != idA || ch[1]["deleted"] != true || body["seq"].(float64) != 3 {
		t.Fatalf("pull: %v", body)
	}
	if got, _ := base64.StdEncoding.DecodeString(ch[0]["data"].(string)); string(got) != "ciphertext" {
		t.Fatal("data mismatch")
	}
	if got, _ := base64.StdEncoding.DecodeString(ch[1]["data"].(string)); string(got) != "sealed tombstone" {
		t.Fatalf("tombstone data: %v", ch[1])
	}
	_, info := do(t, srv, "GET", "/v1/account", tok, nil)
	if info["bytes"].(float64) != float64(len("ciphertext")+len("sealed tombstone")) {
		t.Fatalf("bytes with tombstone: %v", info)
	}
	_, body = do(t, srv, "GET", "/v1/changes?since=2&limit=1", tok, nil)
	if ch := changesOf(body); len(ch) != 1 || body["more"] != false {
		t.Fatalf("page: %v", body)
	}
	_, body = do(t, srv, "GET", "/v1/changes?since=0&limit=1", tok, nil)
	if body["more"] != true || body["seq"].(float64) != 2 {
		t.Fatalf("more: %v", body)
	}
	// Invalid input.
	for _, bad := range []map[string]any{
		{"kind": "note", "id": "XYZ", "base": 0, "data": data},
		{"kind": "evil", "id": idA, "base": 0, "data": data},
		{"kind": "note", "id": idA, "base": 0},
		{"kind": "note", "id": idA, "base": 3, "deleted": true}, // tombstone without sealed data
	} {
		if code, _ := do(t, srv, "POST", "/v1/changes", tok, map[string]any{"changes": []any{bad}}); code != 400 {
			t.Fatalf("bad %v: %d", bad, code)
		}
	}
	// Accounts are isolated.
	other := signup(t, srv)
	if _, body := do(t, srv, "GET", "/v1/changes", other, nil); len(changesOf(body)) != 0 {
		t.Fatal("leak between accounts")
	}
}

func TestLongPoll(t *testing.T) {
	srv := newTestServer(t, nil)
	tok := signup(t, srv)
	done := make(chan map[string]any)
	go func() {
		_, body := do(t, srv, "GET", "/v1/changes?since=0&wait=10", tok, nil)
		done <- body
	}()
	time.Sleep(200 * time.Millisecond)
	do(t, srv, "POST", "/v1/changes", tok, map[string]any{"changes": []any{
		map[string]any{"kind": "note", "id": idA, "base": 0, "data": []byte("x")}}})
	select {
	case body := <-done:
		if len(changesOf(body)) != 1 {
			t.Fatalf("long poll: %v", body)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("long poll not woken")
	}
}

func TestBlobs(t *testing.T) {
	srv := newTestServer(t, func(c *config) { c.maxAccountBytes = 3000 })
	tok := signup(t, srv)
	blob := bytes.Repeat([]byte{7}, 1000)
	_, body := do(t, srv, "POST", "/v1/blobs/missing", tok, map[string]any{"ids": []string{idA, idB}})
	if len(body["missing"].([]any)) != 2 {
		t.Fatalf("missing: %v", body)
	}
	if code, _ := do(t, srv, "PUT", "/v1/blobs/"+idA, tok, blob); code != 204 {
		t.Fatalf("put: %d", code)
	}
	if code, _ := do(t, srv, "PUT", "/v1/blobs/"+idA, tok, []byte("ignored")); code != 204 {
		t.Fatalf("put again: %d", code)
	}
	req, _ := http.NewRequest("GET", srv.URL+"/v1/blobs/"+idA, nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !bytes.Equal(got, blob) {
		t.Fatal("blob mismatch")
	}
	_, body = do(t, srv, "POST", "/v1/blobs/missing", tok, map[string]any{"ids": []string{idA, idB}})
	if m := body["missing"].([]any); len(m) != 1 || m[0] != idB {
		t.Fatalf("missing after put: %v", body)
	}
	if code, body := do(t, srv, "PUT", "/v1/blobs/"+idB, tok, bytes.Repeat([]byte{1}, 2500)); code != 507 {
		t.Fatalf("quota: %d %v", code, body)
	}
	_, body = do(t, srv, "GET", "/v1/blobs", tok, nil)
	if l := body["blobs"].([]any); len(l) != 1 || l[0].(map[string]any)["size"].(float64) != 1000 {
		t.Fatalf("list: %v", body)
	}
	if code, _ := do(t, srv, "DELETE", "/v1/blobs/"+idA, tok, nil); code != 204 {
		t.Fatalf("delete: %d", code)
	}
	if code, _ := do(t, srv, "GET", "/v1/blobs/"+idA, tok, nil); code != 404 {
		t.Fatalf("get deleted: %d", code)
	}
	_, info := do(t, srv, "GET", "/v1/account", tok, nil)
	if info["bytes"].(float64) != 0 {
		t.Fatalf("bytes after delete: %v", info)
	}
	other := signup(t, srv)
	do(t, srv, "PUT", "/v1/blobs/"+idB, tok, blob)
	if code, _ := do(t, srv, "GET", "/v1/blobs/"+idB, other, nil); code != 404 {
		t.Fatal("blob visible to other account")
	}
	if code, _ := do(t, srv, "PUT", "/v1/blobs/"+strings.Repeat("0", 31)+"Z", tok, blob); code != 400 {
		t.Fatal("bad blob id accepted")
	}
	if code, _ := do(t, srv, "PUT", "/v1/blobs/"+idA, tok, bytes.Repeat([]byte{1}, 2<<20)); code != 413 {
		t.Fatal("too large blob accepted")
	}
}

func TestBlobFileMissing(t *testing.T) {
	var dir string
	srv := newTestServer(t, func(c *config) { dir = c.dataDir })
	tok := signup(t, srv)
	do(t, srv, "PUT", "/v1/blobs/"+idA, tok, []byte("sealed"))
	files, _ := filepath.Glob(filepath.Join(dir, "blobs", "*", idA))
	if len(files) != 1 || os.Remove(files[0]) != nil {
		t.Fatalf("blob file: %v", files)
	}
	if code, _ := do(t, srv, "GET", "/v1/blobs/"+idA, tok, nil); code != 404 {
		t.Fatalf("get blob with no file: %d", code)
	}
}
