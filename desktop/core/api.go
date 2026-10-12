package core

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var ErrUnauthorized = errors.New("The server does not know this sync key.")

// HTTPError is an error status of the server (PROTOCOL.md §6, Limits and errors).
type HTTPError struct {
	Status int
	Code   string
}

func (e *HTTPError) Error() string {
	if e.Code == "" {
		return fmt.Sprintf("Server error %d.", e.Status)
	}
	return fmt.Sprintf("Server error %d: %s.", e.Status, e.Code)
}

type RemoteChange struct {
	Kind    string `json:"kind"`
	ID      string `json:"id"`
	Seq     int64  `json:"seq"`
	Deleted bool   `json:"deleted"`
	Data    []byte `json:"data"`
}

type ChangesPage struct {
	Changes []RemoteChange `json:"changes"`
	Seq     int64          `json:"seq"`
	More    bool           `json:"more"`
}

type OutgoingChange struct {
	Kind    string `json:"kind"`
	ID      string `json:"id"`
	Base    int64  `json:"base"`
	Deleted bool   `json:"deleted"`
	Data    []byte `json:"data"`
}

type PushResult struct {
	Kind     string `json:"kind"`
	ID       string `json:"id"`
	Seq      int64  `json:"seq"`
	Conflict bool   `json:"conflict"`
}

type BlobInfo struct {
	ID      string `json:"id"`
	Size    int64  `json:"size"`
	Created int64  `json:"created"`
}

// API is the HTTP client. No cookies, no cache, TLS 1.2 or newer.
type API struct {
	Base   *url.URL
	bearer string
	client *http.Client
}

// ValidateServer accepts https, or http only for loopback addresses (local testing).
func ValidateServer(text string) (*url.URL, error) {
	s := strings.TrimRight(strings.TrimSpace(text), "/")
	u, err := url.Parse(s)
	if err != nil || u.Host == "" || u.RawQuery != "" || u.User != nil {
		return nil, errors.New("Enter the server address, for example https://notes.example.com.")
	}
	switch strings.ToLower(u.Scheme) {
	case "https":
		return u, nil
	case "http":
		if h := u.Hostname(); h == "localhost" || net.ParseIP(h).IsLoopback() {
			return u, nil
		}
	}
	return nil, errors.New("The server address must start with https:// (http:// only for localhost).")
}

func NewAPI(base *url.URL, keys Keys) *API {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	transport.ResponseHeaderTimeout = 90 * time.Second
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	return &API{Base: base, bearer: keys.Bearer(), client: client}
}

func (a *API) request(ctx context.Context, method, path string, query url.Values, body io.Reader) (*http.Request, error) {
	u := *a.Base
	u.Path = strings.TrimRight(u.Path, "/") + "/" + path
	u.RawQuery = query.Encode()
	req, err := http.NewRequestWithContext(ctx, method, u.String(), body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+a.bearer)
	req.Header.Set("User-Agent", "NotallyXYZ")
	return req, nil
}

func check(resp *http.Response) error {
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	if resp.StatusCode == http.StatusUnauthorized {
		return ErrUnauthorized
	}
	var e struct {
		Error string `json:"error"`
	}
	_ = json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&e)
	return &HTTPError{Status: resp.StatusCode, Code: e.Error}
}

func (a *API) do(ctx context.Context, method, path string, query url.Values, in, out any, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	req, err := a.request(ctx, method, path, query, body)
	if err != nil {
		return err
	}
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := check(resp); err != nil {
		return err
	}
	if out == nil {
		return nil
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64<<20)).Decode(out); err != nil {
		return errors.New("Unexpected server response.")
	}
	return nil
}

const shortTimeout = 90 * time.Second

// CreateAccount returns true if the account was created, false if it existed.
func (a *API) CreateAccount(ctx context.Context, invite string) (bool, error) {
	var out struct {
		Created bool `json:"created"`
	}
	err := a.do(ctx, "POST", "v1/account", nil, map[string]string{"invite": invite}, &out, shortTimeout)
	return out.Created, err
}

func (a *API) AccountInfo(ctx context.Context) (map[string]int64, error) {
	out := map[string]int64{}
	return out, a.do(ctx, "GET", "v1/account", nil, nil, &out, shortTimeout)
}

func (a *API) DeleteAccount(ctx context.Context) error {
	return a.do(ctx, "DELETE", "v1/account", nil, nil, nil, shortTimeout)
}

func (a *API) Changes(ctx context.Context, since int64, limit, wait int) (ChangesPage, error) {
	var out ChangesPage
	q := url.Values{"since": {strconv.FormatInt(since, 10)}, "limit": {strconv.Itoa(limit)}, "wait": {strconv.Itoa(wait)}}
	err := a.do(ctx, "GET", "v1/changes", q, nil, &out, time.Duration(wait+60)*time.Second)
	return out, err
}

func (a *API) Push(ctx context.Context, changes []OutgoingChange) ([]PushResult, error) {
	var out struct {
		Results []PushResult `json:"results"`
	}
	err := a.do(ctx, "POST", "v1/changes", nil, map[string]any{"changes": changes}, &out, 10*time.Minute)
	return out.Results, err
}

func (a *API) MissingBlobs(ctx context.Context, ids []string) ([]string, error) {
	var out struct {
		Missing []string `json:"missing"`
	}
	err := a.do(ctx, "POST", "v1/blobs/missing", nil, map[string]any{"ids": ids}, &out, shortTimeout)
	return out.Missing, err
}

func (a *API) PutBlob(ctx context.Context, id, file string) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()
	f, err := os.Open(file)
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return err
	}
	req, err := a.request(ctx, "PUT", "v1/blobs/"+id, nil, f)
	if err != nil {
		return err
	}
	req.ContentLength = st.Size()
	req.Header.Set("Content-Type", "application/octet-stream")
	resp, err := a.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return check(resp)
}

// GetBlob downloads into target (written only on success).
func (a *API) GetBlob(ctx context.Context, id, target string) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()
	req, err := a.request(ctx, "GET", "v1/blobs/"+id, nil, nil)
	if err != nil {
		return err
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := check(resp); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(target), ".download-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := io.Copy(tmp, resp.Body); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), target)
}

func (a *API) ListBlobs(ctx context.Context) ([]BlobInfo, error) {
	var out struct {
		Blobs []BlobInfo `json:"blobs"`
	}
	return out.Blobs, a.do(ctx, "GET", "v1/blobs", nil, nil, &out, shortTimeout)
}

func (a *API) DeleteBlob(ctx context.Context, id string) error {
	return a.do(ctx, "DELETE", "v1/blobs/"+id, nil, nil, nil, shortTimeout)
}
