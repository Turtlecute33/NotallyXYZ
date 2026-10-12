// Command nxyz-export downloads and decrypts all data of one sync account.
// It reads the sync key from standard input, so that the key does not appear in the
// shell history or the process list:
//
//	security find-generic-password -s notallyxyz-sync -w | nxyz-export -server https://notes.example.com -out ./export
//
// Output: notes/<id>.json (note payloads), labels.json, attachments/<name>.
package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"notallyxyz-server/seal"
)

type change struct {
	Kind    string `json:"kind"`
	ID      string `json:"id"`
	Seq     uint64 `json:"seq"`
	Deleted bool   `json:"deleted"`
	Data    []byte `json:"data"`
}

func main() {
	server := flag.String("server", "", "server URL, e.g. https://notes.example.com")
	out := flag.String("out", "export", "output directory")
	flag.Parse()
	if *server == "" {
		fmt.Fprintln(os.Stderr, "usage: nxyz-export -server URL [-out DIR] < key")
		os.Exit(2)
	}
	line, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil && err != io.EOF {
		fail(err)
	}
	key, err := seal.ParseKey(line)
	if err != nil {
		fail(fmt.Errorf("sync key: %w", err))
	}
	keys := seal.DeriveKeys(key)
	c := client{base: strings.TrimRight(*server, "/") + "/v1", token: base64.RawURLEncoding.EncodeToString(keys.AuthToken)}

	for _, dir := range []string{"notes", "attachments"} {
		if err := os.MkdirAll(filepath.Join(*out, dir), 0o700); err != nil {
			fail(err)
		}
	}
	var labels []json.RawMessage
	var blobNames []string
	notes, skipped := 0, 0
	for since, more := uint64(0), true; more; {
		var page struct {
			Changes []change `json:"changes"`
			Seq     uint64   `json:"seq"`
			More    bool     `json:"more"`
		}
		if err := c.getJSON(fmt.Sprintf("/changes?since=%d&limit=1000", since), &page); err != nil {
			fail(err)
		}
		for _, ch := range page.Changes {
			if ch.Deleted {
				continue
			}
			plain, err := seal.Open(keys.EncKey, seal.AD(ch.Kind, ch.ID), ch.Data)
			if err != nil {
				skipped++
				continue
			}
			var tombstone struct {
				Deleted bool `json:"deleted"`
			}
			if json.Unmarshal(plain, &tombstone) == nil && tombstone.Deleted {
				continue
			}
			switch ch.Kind {
			case "note":
				notes++
				if err := os.WriteFile(filepath.Join(*out, "notes", ch.ID+".json"), plain, 0o600); err != nil {
					fail(err)
				}
				blobNames = append(blobNames, attachmentNames(plain)...)
			case "label":
				labels = append(labels, plain)
			}
		}
		since, more = page.Seq, page.More
	}
	raw, _ := json.MarshalIndent(labels, "", "  ")
	if err := os.WriteFile(filepath.Join(*out, "labels.json"), raw, 0o600); err != nil {
		fail(err)
	}
	files := 0
	for _, name := range blobNames {
		if !safeName(name) {
			continue
		}
		id := seal.BlobID(keys.IDKey, name)
		sealed, err := c.get("/blobs/" + id)
		if err != nil {
			fmt.Fprintf(os.Stderr, "attachment %s: %v\n", name, err)
			continue
		}
		plain, err := seal.Open(keys.EncKey, seal.AD("blob", id), sealed)
		if err != nil {
			skipped++
			continue
		}
		if err := os.WriteFile(filepath.Join(*out, "attachments", name), plain, 0o600); err != nil {
			fail(err)
		}
		files++
	}
	fmt.Printf("%d notes, %d labels, %d attachments, %d records not decryptable\n", notes, len(labels), files, skipped)
}

func attachmentNames(note []byte) []string {
	var n struct {
		Images []struct{ LocalName string } `json:"images"`
		Files  []struct{ LocalName string } `json:"files"`
		Audios []struct{ Name string }      `json:"audios"`
	}
	if json.Unmarshal(note, &n) != nil {
		return nil
	}
	var names []string
	for _, f := range append(n.Images, n.Files...) {
		names = append(names, f.LocalName)
	}
	for _, a := range n.Audios {
		names = append(names, a.Name)
	}
	return names
}

func safeName(name string) bool {
	return name != "" && len(name) <= 255 && !strings.HasPrefix(name, ".") && !strings.ContainsAny(name, "/\\\x00")
}

type client struct{ base, token string }

func (c client) get(path string) ([]byte, error) {
	req, _ := http.NewRequest("GET", c.base+path, nil)
	req.Header.Set("Authorization", "Bearer "+c.token)
	resp, err := (&http.Client{Timeout: 10 * time.Minute}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return body, nil
}

func (c client) getJSON(path string, v any) error {
	body, err := c.get(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(body, v)
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
