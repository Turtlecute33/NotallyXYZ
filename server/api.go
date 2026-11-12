package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	maxRecordBytes   = 8 << 20
	maxRequestBytes  = 32 << 20
	maxPageBytes     = 8 << 20
	maxChangesPerReq = 1000
	maxWait          = 60
	ioTimeout        = 2 * time.Minute // ReadTimeout and WriteTimeout. Long poll and blobs extend them.
	maxHeavy         = 4               // requests that hold a page of changes in memory at one time
)

type api struct {
	cfg     config
	store   *Store
	limiter *limiter
	heavy   chan struct{}
}

type ctxKey int

const (
	ctxAccount ctxKey = iota
	ctxTokenHash
)

func newAPI(cfg config, store *Store) *api {
	return &api{cfg: cfg, store: store, limiter: newLimiter(30, 15*time.Minute), heavy: make(chan struct{}, maxHeavy)}
}

// acquire waits for a slot for memory-heavy work. It reports false if the request ends first.
func (a *api) acquire(r *http.Request) bool {
	select {
	case a.heavy <- struct{}{}:
		return true
	case <-r.Context().Done():
		return false
	}
}

func (a *api) release() { <-a.heavy }

func (a *api) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("POST /v1/account", a.createAccount)
	mux.Handle("GET /v1/account", a.auth(a.getAccount))
	mux.Handle("DELETE /v1/account", a.auth(a.deleteAccount))
	mux.Handle("GET /v1/changes", a.auth(a.getChanges))
	mux.Handle("POST /v1/changes", a.auth(a.postChanges))
	mux.Handle("GET /v1/blobs", a.auth(a.listBlobs))
	mux.Handle("POST /v1/blobs/missing", a.auth(a.missingBlobs))
	mux.Handle("PUT /v1/blobs/{id}", a.auth(a.putBlob))
	mux.Handle("GET /v1/blobs/{id}", a.auth(a.getBlob))
	mux.Handle("DELETE /v1/blobs/{id}", a.auth(a.deleteBlob))
	return secureHeaders(mux)
}

func secureHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Cache-Control", "no-store")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Cross-Origin-Resource-Policy", "same-origin")
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code string) {
	writeJSON(w, status, map[string]string{"error": code})
}

func (a *api) internalError(w http.ResponseWriter, op string, err error) {
	switch {
	case errors.Is(err, errQuota):
		writeError(w, http.StatusInsufficientStorage, "quota_exceeded")
	case errors.Is(err, errNotFound):
		writeError(w, http.StatusNotFound, "not_found")
	case errors.Is(err, errCursorAhead):
		writeError(w, http.StatusConflict, "cursor_ahead")
	default:
		log.Printf("%s: %v", op, err)
		writeError(w, http.StatusInternalServerError, "internal")
	}
}

// clientIP is used only for the in-memory failure counter. It is never logged or stored.
// An IPv6 address counts as its /64 network, because one host can use all of it.
func (a *api) clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if a.cfg.trustProxy {
		// The proxy appends the address that it sees: use the last value of the last line.
		if xff := r.Header.Values("X-Forwarded-For"); len(xff) > 0 {
			parts := strings.Split(xff[len(xff)-1], ",")
			host = strings.TrimSpace(parts[len(parts)-1])
		}
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return host
	}
	if ip = ip.Unmap(); ip.Is6() {
		p, _ := ip.WithZone("").Prefix(64)
		return p.String()
	}
	return ip.String()
}

// tokenHash parses "Authorization: Bearer <base64url 32 bytes>" and returns SHA-256 of the token.
func tokenHash(r *http.Request) ([]byte, bool) {
	h := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if len(h) <= len(prefix) || !strings.EqualFold(h[:len(prefix)], prefix) {
		return nil, false
	}
	token, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(h[len(prefix):]))
	if err != nil || len(token) != 32 {
		return nil, false
	}
	sum := sha256.Sum256(token)
	return sum[:], true
}

// noAuth answers 401 to a request without an Authorization header. Such requests (scanners)
// do not count as failures, so that they cannot block the clients that share their address.
func noAuth(w http.ResponseWriter, r *http.Request) bool {
	if r.Header.Get("Authorization") != "" {
		return false
	}
	writeError(w, http.StatusUnauthorized, "unauthorized")
	return true
}

func (a *api) auth(next http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if noAuth(w, r) {
			return
		}
		ip := a.clientIP(r)
		if a.limiter.blocked(ip) {
			writeError(w, http.StatusTooManyRequests, "rate_limited")
			return
		}
		hash, ok := tokenHash(r)
		var acct string
		if ok {
			acct, ok = a.store.Lookup(hash)
		}
		if !ok {
			a.limiter.fail(ip)
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		ctx := context.WithValue(r.Context(), ctxAccount, acct)
		ctx = context.WithValue(ctx, ctxTokenHash, hash)
		next(w, r.WithContext(ctx))
	})
}

func account(r *http.Request) string { return r.Context().Value(ctxAccount).(string) }

func validID(id string) bool {
	if len(id) != 32 {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func validKind(k string) bool { return k == "note" || k == "label" }

func decodeJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeError(w, http.StatusRequestEntityTooLarge, "too_large")
		} else {
			writeError(w, http.StatusBadRequest, "bad_request")
		}
		return false
	}
	return true
}

func (a *api) createAccount(w http.ResponseWriter, r *http.Request) {
	if noAuth(w, r) {
		return
	}
	ip := a.clientIP(r)
	if a.limiter.blocked(ip) {
		writeError(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	hash, ok := tokenHash(r)
	if !ok {
		a.limiter.fail(ip)
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	var body struct {
		Invite string `json:"invite"`
	}
	// The body has only the invite. This limit stops large bodies before the account check.
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	if !decodeJSON(w, r, &body) {
		return
	}
	if _, exists := a.store.Lookup(hash); exists {
		writeJSON(w, http.StatusOK, map[string]bool{"created": false})
		return
	}
	if a.cfg.signupToken == "" {
		writeError(w, http.StatusForbidden, "signup_disabled")
		return
	}
	want := sha256.Sum256([]byte(a.cfg.signupToken))
	got := sha256.Sum256([]byte(body.Invite))
	if subtle.ConstantTimeCompare(want[:], got[:]) != 1 {
		a.limiter.fail(ip)
		writeError(w, http.StatusForbidden, "invalid_invite")
		return
	}
	created, err := a.store.CreateAccount(hash, a.cfg.maxAccounts)
	if errors.Is(err, errAccountsMax) {
		writeError(w, http.StatusForbidden, "accounts_limit")
		return
	}
	if err != nil {
		a.internalError(w, "create account", err)
		return
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	writeJSON(w, status, map[string]bool{"created": created})
}

func (a *api) getAccount(w http.ResponseWriter, r *http.Request) {
	info, err := a.store.Info(account(r))
	if err != nil {
		a.internalError(w, "account info", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]int64{
		"seq":             int64(info.Seq),
		"bytes":           info.Bytes,
		"maxBlobBytes":    a.cfg.maxBlobBytes,
		"maxAccountBytes": a.cfg.maxAccountBytes,
	})
}

func (a *api) deleteAccount(w http.ResponseWriter, r *http.Request) {
	hash := r.Context().Value(ctxTokenHash).([]byte)
	if err := a.store.DeleteAccount(hash, account(r)); err != nil {
		a.internalError(w, "delete account", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func queryInt(r *http.Request, key string, def, min, max int64) (int64, bool) {
	s := r.URL.Query().Get(key)
	if s == "" {
		return def, true
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil || v < min || v > max {
		return 0, false
	}
	return v, true
}

func (a *api) getChanges(w http.ResponseWriter, r *http.Request) {
	since, ok1 := queryInt(r, "since", 0, 0, 1<<62)
	limit, ok2 := queryInt(r, "limit", 500, 1, 1000)
	wait, ok3 := queryInt(r, "wait", 0, 0, maxWait)
	if !ok1 || !ok2 || !ok3 {
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	acct := account(r)
	rc := http.NewResponseController(w)
	_ = rc.SetWriteDeadline(time.Now().Add(time.Duration(wait)*time.Second + ioTimeout))

	// Register before reading, so that a change between read and wait is not missed.
	woken := a.store.wait(acct)
	if !a.acquire(r) {
		return
	}
	changes, last, more, err := a.store.Changes(acct, uint64(since), int(limit), maxPageBytes)
	if err == nil && len(changes) == 0 && wait > 0 {
		a.release() // the wait holds no slot
		select {
		case <-woken:
		case <-time.After(time.Duration(wait) * time.Second):
		case <-r.Context().Done():
			return
		}
		if !a.acquire(r) {
			return
		}
		changes, last, more, err = a.store.Changes(acct, uint64(since), int(limit), maxPageBytes)
	}
	defer a.release()
	if err != nil {
		a.internalError(w, "changes", err)
		return
	}
	if changes == nil {
		changes = []Change{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"changes": changes, "seq": last, "more": more})
}

func (a *api) postChanges(w http.ResponseWriter, r *http.Request) {
	// A large batch on a slow link takes longer than ioTimeout. Read it before taking a slot,
	// so that a slow client cannot hold one.
	_ = http.NewResponseController(w).SetReadDeadline(time.Now().Add(30 * time.Minute))
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxRequestBytes))
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeError(w, http.StatusRequestEntityTooLarge, "too_large")
		} else {
			writeError(w, http.StatusBadRequest, "bad_request")
		}
		return
	}
	r.Body = io.NopCloser(bytes.NewReader(data))
	if !a.acquire(r) {
		return
	}
	defer a.release()
	var body struct {
		Changes []ChangeIn `json:"changes"`
	}
	if !decodeJSON(w, r, &body) {
		return
	}
	if len(body.Changes) == 0 || len(body.Changes) > maxChangesPerReq {
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	seen := make(map[string]bool, len(body.Changes))
	for _, ch := range body.Changes {
		key := ch.Kind + ":" + ch.ID
		if !validKind(ch.Kind) || !validID(ch.ID) || seen[key] ||
			len(ch.Data) == 0 || len(ch.Data) > maxRecordBytes {
			writeError(w, http.StatusBadRequest, "bad_request")
			return
		}
		seen[key] = true
	}
	results, err := a.store.Apply(account(r), body.Changes, a.cfg.maxAccountBytes)
	if err != nil {
		a.internalError(w, "apply changes", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"results": results})
}

func (a *api) listBlobs(w http.ResponseWriter, r *http.Request) {
	list, err := a.store.ListBlobs(account(r))
	if err != nil {
		a.internalError(w, "list blobs", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"blobs": list})
}

func (a *api) missingBlobs(w http.ResponseWriter, r *http.Request) {
	var body struct {
		IDs []string `json:"ids"`
	}
	if !decodeJSON(w, r, &body) {
		return
	}
	if len(body.IDs) > 10000 {
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	for _, id := range body.IDs {
		if !validID(id) {
			writeError(w, http.StatusBadRequest, "bad_request")
			return
		}
	}
	missing, err := a.store.Missing(account(r), body.IDs)
	if err != nil {
		a.internalError(w, "missing blobs", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"missing": missing})
}

func (a *api) putBlob(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validID(id) || r.ContentLength == 0 {
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	if r.ContentLength < 0 {
		writeError(w, http.StatusLengthRequired, "length_required")
		return
	}
	if a.cfg.maxBlobBytes > 0 && r.ContentLength > a.cfg.maxBlobBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "too_large")
		return
	}
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Now().Add(30 * time.Minute))
	_ = rc.SetWriteDeadline(time.Now().Add(31 * time.Minute))
	err := a.store.PutBlob(account(r), id, r.ContentLength, r.Body, a.cfg.maxAccountBytes)
	if err != nil {
		a.internalError(w, "put blob", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *api) getBlob(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validID(id) {
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	f, err := a.store.OpenBlob(account(r), id)
	if errors.Is(err, os.ErrNotExist) {
		// Delete the entry of the lost file, so that "missing" reports the blob and the
		// clients upload it again.
		log.Print("get blob: stored blob has no file")
		if err = a.store.DeleteBlob(account(r), id); err == nil {
			err = errNotFound
		}
	}
	if err != nil {
		a.internalError(w, "get blob", err)
		return
	}
	defer f.Close()
	rc := http.NewResponseController(w)
	_ = rc.SetWriteDeadline(time.Now().Add(30 * time.Minute))
	w.Header().Set("Content-Type", "application/octet-stream")
	http.ServeContent(w, r, "", time.Time{}, f)
}

func (a *api) deleteBlob(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validID(id) {
		writeError(w, http.StatusBadRequest, "bad_request")
		return
	}
	if err := a.store.DeleteBlob(account(r), id); err != nil {
		a.internalError(w, "delete blob", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
