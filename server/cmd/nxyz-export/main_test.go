package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"notallyxyz-server/seal"
)

// The test binary runs main when the tests start it again with this variable.
func TestMain(m *testing.M) {
	if os.Getenv("NXYZ_EXPORT_MAIN") == "1" {
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

var testKey = make([]byte, 32)

// export runs the tool against a server that answers GET /v1/changes with pages and
// GET /v1/blobs/{id} with blobs. It returns the exit code, stderr and the output directory.
func export(t *testing.T, changes func(since string) any, blobs map[string][]byte) (int, string, string) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if id, ok := strings.CutPrefix(r.URL.Path, "/v1/blobs/"); ok {
			if b, ok := blobs[id]; ok {
				w.Write(b)
			} else {
				http.NotFound(w, r)
			}
			return
		}
		switch page := changes(r.URL.Query().Get("since")).(type) {
		case []byte:
			w.Write(page)
		default:
			json.NewEncoder(w).Encode(page)
		}
	}))
	defer srv.Close()
	out := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-server", srv.URL, "-out", out)
	cmd.Env = append(os.Environ(), "NXYZ_EXPORT_MAIN=1")
	cmd.Stdin = strings.NewReader(seal.FormatKey(testKey) + "\n")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	_ = cmd.Run()
	if ctx.Err() != nil {
		t.Error("the export did not end")
	}
	return cmd.ProcessState.ExitCode(), stderr.String(), out
}

func sealed(kind, id string, plain string) []byte {
	salt := make([]byte, seal.SaltSize)
	rand.Read(salt)
	return seal.Seal(seal.DeriveKeys(testKey).EncKey, salt, seal.AD(kind, id), []byte(plain))
}

type testPage struct {
	Changes []change `json:"changes"`
	Seq     uint64   `json:"seq"`
	More    bool     `json:"more"`
}

const noteID = "0123456789abcdef0123456789abcdef"

func TestExport(t *testing.T) {
	keys := seal.DeriveKeys(testKey)
	blobID := seal.BlobID(keys.IDKey, "a.jpg")
	note := change{"note", noteID, sealed("note", noteID, `{"title":"t","images":[{"localName":"a.jpg"}]}`)}
	label := change{"label", seal.LabelID(keys.IDKey, "work"), sealed("label", seal.LabelID(keys.IDKey, "work"), `{"value":"work"}`)}
	twoPages := func(since string) any {
		if since == "0" {
			return testPage{[]change{note}, 1, true}
		}
		return testPage{[]change{label}, 2, false}
	}
	code, stderr, out := export(t, twoPages, map[string][]byte{blobID: sealed("blob", blobID, "image")})
	if code != 0 {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if b, err := os.ReadFile(filepath.Join(out, "attachments", "a.jpg")); err != nil || string(b) != "image" {
		t.Fatalf("attachment: %q %v", b, err)
	}

	// An incomplete export ends with an error.
	if code, stderr, _ := export(t, twoPages, nil); code != 1 || !strings.Contains(stderr, "not complete") {
		t.Errorf("missing attachment: exit %d: %s", code, stderr)
	}
	bad := change{"note", noteID, []byte("not sealed")}
	if code, stderr, _ := export(t, func(string) any { return testPage{[]change{bad}, 1, false} }, nil); code != 1 || !strings.Contains(stderr, "not complete") {
		t.Errorf("rejected record: exit %d: %s", code, stderr)
	}

	// A broken or hostile server cannot make the tool loop or read without a limit.
	if code, stderr, _ := export(t, func(string) any { return testPage{nil, 0, true} }, nil); code != 1 || !strings.Contains(stderr, "cursor") {
		t.Errorf("cursor does not move: exit %d: %s", code, stderr)
	}
	huge := []byte(`{"changes":[],"seq":1,"more":false` + strings.Repeat(" ", 65<<20) + `}`)
	if code, stderr, _ := export(t, func(string) any { return huge }, nil); code != 1 || !strings.Contains(stderr, "too large") {
		t.Errorf("response over the limit: exit %d: %s", code, stderr)
	}
}

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
	if _, err := (client{base: srv.URL, token: "secret"}).get("/account", maxJSONBytes); err == nil {
		t.Fatal("redirect followed")
	}
	if leaked.Load() {
		t.Fatal("token sent to the redirect target")
	}
}
