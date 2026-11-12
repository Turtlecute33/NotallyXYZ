package main

import (
	"bytes"
	"errors"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"

	"notallyxyz-desktop/core"
)

var mimeTypes = map[string]string{
	".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".gif": "image/gif",
	".webp": "image/webp", ".bmp": "image/bmp", ".avif": "image/avif", ".heic": "image/heic",
	".m4a": "audio/mp4", ".mp4": "audio/mp4", ".aac": "audio/aac", ".mp3": "audio/mpeg",
	".ogg": "audio/ogg", ".opus": "audio/ogg", ".wav": "audio/wav", ".3gp": "audio/3gpp",
	".amr": "audio/amr", ".webm": "audio/webm", ".pdf": "application/pdf", ".txt": "text/plain",
}

func mimeFor(name string) string {
	if m, ok := mimeTypes[strings.ToLower(filepath.Ext(name))]; ok {
		return m
	}
	return "application/octet-stream"
}

// attachmentHandler serves decrypted images and audio to the web view at /att/<localName>.
// Only from memory, never cached on disk, never as a document that could run scripts.
func (a *App) attachmentHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name, ok := strings.CutPrefix(r.URL.Path, "/att/")
		store, _, err := a.current()
		if !ok || err != nil || !core.IsSafeFileName(name) {
			http.NotFound(w, r)
			return
		}
		mime := strings.ToLower(r.URL.Query().Get("m"))
		if mime == "" {
			mime = mimeFor(name)
		}
		if !(strings.HasPrefix(mime, "image/") || strings.HasPrefix(mime, "audio/")) || strings.Contains(mime, "svg") {
			http.Error(w, "unsupported", http.StatusUnsupportedMediaType)
			return
		}
		data, err := store.AttachmentData(name)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		h := w.Header()
		h.Set("Content-Type", mime)
		h.Set("Cache-Control", "no-store")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Content-Security-Policy", "default-src 'none'; sandbox")
		http.ServeContent(w, r, "", time.Time{}, bytes.NewReader(data))
	})
}

// AddAttachments asks for files and copies them sealed into the cache. kind: "image" or "file".
func (a *App) AddAttachments(kind string) ([]core.FileAttachment, error) {
	store, _, err := a.current()
	if err != nil {
		return nil, err
	}
	opts := wruntime.OpenDialogOptions{Title: "Add files"}
	if kind == "image" {
		opts = wruntime.OpenDialogOptions{Title: "Add images", Filters: []wruntime.FileFilter{
			{DisplayName: "Images", Pattern: "*.jpg;*.jpeg;*.png;*.gif;*.webp;*.bmp;*.JPG;*.JPEG;*.PNG;*.GIF;*.WEBP;*.BMP"}}}
	}
	files, err := wruntime.OpenMultipleFilesDialog(a.ctx, opts)
	if err != nil {
		return nil, err
	}
	out := []core.FileAttachment{}
	for _, f := range files {
		mime := mimeFor(f)
		if kind == "image" && !strings.HasPrefix(mime, "image/") {
			continue
		}
		att, err := store.ImportAttachment(f, mime)
		if err != nil {
			return out, err
		}
		out = append(out, att)
	}
	return out, nil
}

// Only files of these types open with the default app. Other files could run code: they can
// only be saved.
var openable = map[string]bool{
	".jpg": true, ".jpeg": true, ".png": true, ".gif": true, ".webp": true, ".bmp": true, ".avif": true, ".heic": true,
	".mp3": true, ".m4a": true, ".aac": true, ".ogg": true, ".opus": true, ".wav": true, ".flac": true, ".3gp": true,
	".amr": true, ".mp4": true, ".webm": true, ".mov": true, ".mkv": true, ".pdf": true, ".txt": true,
}

// OpenAttachment writes a plaintext copy into a private temporary folder (removed on quit)
// and opens it with the default app.
func (a *App) OpenAttachment(localName, originalName string) error {
	store, _, err := a.current()
	if err != nil {
		return err
	}
	name := safeName(originalName, localName)
	if !openable[strings.ToLower(filepath.Ext(name))] {
		return a.SaveAttachment(localName, originalName)
	}
	data, err := store.AttachmentData(localName)
	if err != nil {
		return errors.New("The attachment is not downloaded yet.")
	}
	a.mu.Lock()
	if a.tempDir == "" {
		a.tempDir, err = os.MkdirTemp("", "notallyxyz-")
	}
	dir := a.tempDir
	a.mu.Unlock()
	if err != nil {
		return err
	}
	sub, err := os.MkdirTemp(dir, "f")
	if err != nil {
		return err
	}
	path := filepath.Join(sub, name)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return err
	}
	markFromInternet(path)
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", path)
	case "darwin":
		cmd = exec.Command("open", path)
	default:
		cmd = exec.Command("xdg-open", path)
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	go cmd.Wait()
	return nil
}

func (a *App) SaveAttachment(localName, originalName string) error {
	store, _, err := a.current()
	if err != nil {
		return err
	}
	data, err := store.AttachmentData(localName)
	if err != nil {
		return errors.New("The attachment is not downloaded yet.")
	}
	path, err := wruntime.SaveFileDialog(a.ctx, wruntime.SaveDialogOptions{
		Title: "Save attachment", DefaultFilename: safeName(originalName, localName), CanCreateDirectories: true})
	if err != nil || path == "" {
		return err
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return err
	}
	markFromInternet(path)
	return nil
}

// markFromInternet adds the Mark of the Web on Windows, so that Windows and the app that opens
// the file treat it like a download (SmartScreen, protected view).
func markFromInternet(path string) {
	if runtime.GOOS == "windows" {
		_ = os.WriteFile(path+":Zone.Identifier", []byte("[ZoneTransfer]\r\nZoneId=3\r\n"), 0o600)
	}
}

// safeName makes a file name for Windows and Linux from the attachment name, else from fallback.
func safeName(name, fallback string) string {
	for _, n := range []string{name, fallback} {
		n = filepath.Base(strings.ReplaceAll(n, `\`, "/"))
		n = strings.Map(func(r rune) rune {
			if r < 32 || r == 127 || strings.ContainsRune(`<>:"/\|?*`, r) {
				return '_'
			}
			return r
		}, n)
		// Long names fail in Windows paths. Keep the extension.
		if r := []rune(n); len(r) > 100 {
			ext := []rune(filepath.Ext(n))
			if len(ext) > 10 {
				ext = nil
			}
			n = string(r[:100-len(ext)]) + string(ext)
		}
		// Windows removes trailing dots and spaces, which can change the type: "a.exe." is "a.exe".
		n = strings.TrimRight(n, ". ")
		if n == "" || strings.HasPrefix(n, ".") {
			continue
		}
		if base, _, _ := strings.Cut(n, "."); reservedName(base) {
			n = "_" + n
		}
		return n
	}
	return "attachment"
}

// reservedName: Windows opens a device for these names, also with an extension ("nul.txt").
func reservedName(base string) bool {
	b := strings.ToUpper(strings.TrimRight(base, " "))
	switch b {
	case "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$":
		return true
	}
	if len(b) < 4 || (b[:3] != "COM" && b[:3] != "LPT") {
		return false
	}
	switch b[3:] {
	case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "¹", "²", "³":
		return true
	}
	return false
}

// cleanStaleTemp removes plaintext copies left by a crash.
func cleanStaleTemp() {
	dirs, _ := filepath.Glob(filepath.Join(os.TempDir(), "notallyxyz-*"))
	for _, d := range dirs {
		if st, err := os.Stat(d); err == nil && st.IsDir() && time.Since(st.ModTime()) > time.Hour {
			_ = os.RemoveAll(d)
		}
	}
}
