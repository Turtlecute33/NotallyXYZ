package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/wailsapp/wails/v2/pkg/options"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"

	"notallyxyz-desktop/core"
)

// App is the bridge to the web UI: every exported method is callable from JavaScript.
type App struct {
	ctx   context.Context
	paths paths

	mu       sync.Mutex
	config   Config
	settings Settings
	store    *core.NoteStore
	engine   *core.Engine
	tempDir  string
	stop     chan struct{}
	notify   bool
}

// Config is device state that is not a preference.
type Config struct {
	Server string `json:"server"`
}

// Settings are the UI preferences (same set as the macOS app).
type Settings struct {
	Theme           string `json:"theme"`    // system | light | dark
	TextSize        string `json:"textSize"` // small | default | large | extraLarge
	Layout          string `json:"layout"`   // grid | list
	ShowPreview     bool   `json:"showPreview"`
	PreviewLines    int    `json:"previewLines"` // 1–10
	PreviewItems    int    `json:"previewItems"` // 1–10
	CardSize        string `json:"cardSize"`     // fit | small | medium | large
	ShowLabels      bool   `json:"showLabels"`
	ShowImages      bool   `json:"showImages"`
	ShowDate        bool   `json:"showDate"`
	SortBy          string `json:"sortBy"` // modified | created | title | color
	SortAscending   bool   `json:"sortAscending"`
	AutoSortChecked bool   `json:"autoSortChecked"`
}

func defaultSettings() Settings {
	return Settings{Theme: "system", TextSize: "default", Layout: "grid", ShowPreview: true, PreviewLines: 8,
		PreviewItems: 4, CardSize: "fit", ShowLabels: true, ShowImages: true, ShowDate: true, SortBy: "modified", AutoSortChecked: true}
}

func (s *Settings) clean() {
	d := defaultSettings()
	oneOf := func(v *string, def string, allowed ...string) {
		for _, a := range allowed {
			if *v == a {
				return
			}
		}
		*v = def
	}
	oneOf(&s.Theme, d.Theme, "system", "light", "dark")
	oneOf(&s.TextSize, d.TextSize, "small", "default", "large", "extraLarge")
	oneOf(&s.Layout, d.Layout, "grid", "list")
	oneOf(&s.CardSize, d.CardSize, "fit", "small", "medium", "large")
	oneOf(&s.SortBy, d.SortBy, "modified", "created", "title", "color")
	s.PreviewLines = min(10, max(1, s.PreviewLines))
	s.PreviewItems = min(10, max(1, s.PreviewItems))
}

func NewApp() *App { return &App{paths: appPaths()} }

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	a.settings = defaultSettings()
	_ = readJSON(a.paths.settingsFile(), &a.settings)
	a.settings.clean()
	_ = readJSON(a.paths.configFile(), &a.config)
	cleanStaleTemp()
	if runtime.GOOS != "darwin" { // macOS needs an app bundle; the macOS app is separate anyway
		a.notify = wruntime.InitializeNotifications(ctx) == nil
		wruntime.OnNotificationResponse(ctx, func(r wruntime.NotificationResult) {
			id := r.Response.ID
			if v, ok := r.Response.UserInfo["id"].(string); ok {
				id = v
			}
			if r.Error == nil && id != "" {
				wruntime.WindowShow(ctx)
				wruntime.EventsEmit(ctx, "open", id)
			}
		})
	}
	if u, err := core.ValidateServer(a.config.Server); err == nil {
		if text, _, err := loadKey(a.paths); err == nil {
			if keys, err := core.ParseKeys(text); err == nil {
				if err := a.open(u.String(), keys); err != nil {
					wruntime.LogErrorf(ctx, "open cache: %v", err)
				}
			}
		}
	}
}

func (a *App) shutdown(context.Context) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.closeLocked()
	if a.notify {
		wruntime.CleanupNotifications(a.ctx)
	}
}

func (a *App) secondInstance(options.SecondInstanceData) {
	wruntime.WindowUnminimise(a.ctx)
	wruntime.WindowShow(a.ctx)
}

func (a *App) closeLocked() {
	if a.stop != nil {
		close(a.stop)
		a.stop = nil
	}
	if a.engine != nil {
		a.engine.Stop()
		a.engine = nil
	}
	if a.store != nil {
		a.store.Close()
		a.store = nil
	}
	if a.tempDir != "" {
		os.RemoveAll(a.tempDir)
		a.tempDir = ""
	}
}

// open starts the store and the sync engine for a connected account.
func (a *App) open(server string, keys core.Keys) error {
	u, err := core.ValidateServer(server)
	if err != nil {
		return err
	}
	store, err := core.OpenNoteStore(a.paths.cacheDir(), keys)
	if err != nil {
		return err
	}
	engine := core.NewEngine(store, core.NewAPI(u, keys))
	store.OnChange = func() { wruntime.EventsEmit(a.ctx, "changed") }
	store.OnLocalChange = func() { engine.Schedule(2 * time.Second) }
	engine.OnStatus = func(st core.SyncStatus) { wruntime.EventsEmit(a.ctx, "status", st) }
	a.mu.Lock()
	a.store, a.engine, a.stop = store, engine, make(chan struct{})
	stop := a.stop
	a.mu.Unlock()
	go engine.Sync()
	engine.StartLive()
	go a.reminderLoop(store, stop)
	return nil
}

func (a *App) current() (*core.NoteStore, *core.Engine, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.store == nil {
		return nil, nil, errors.New("not connected")
	}
	return a.store, a.engine, nil
}

// State

type State struct {
	Connected  bool            `json:"connected"`
	Server     string          `json:"server"`
	KeyInFile  bool            `json:"keyInFile"`
	Settings   Settings        `json:"settings"`
	Status     core.SyncStatus `json:"status"`
	Version    string          `json:"version"`
	Platform   string          `json:"platform"`
	CanNotify  bool            `json:"canNotify"`
	DataFolder string          `json:"dataFolder"`
}

func (a *App) GetState() State {
	a.mu.Lock()
	defer a.mu.Unlock()
	st := State{Connected: a.store != nil, Server: a.config.Server, Settings: a.settings, Version: version,
		Platform: runtime.GOOS, CanNotify: a.notify, DataFolder: a.paths.data}
	if a.engine != nil {
		st.Status = a.engine.Status()
	}
	if a.store != nil {
		_, st.KeyInFile, _ = loadKey(a.paths)
	}
	return st
}

func (a *App) SetSettings(s Settings) (Settings, error) {
	s.clean()
	a.mu.Lock()
	a.settings = s
	a.mu.Unlock()
	return s, writeJSON(a.paths.settingsFile(), s)
}

// Setup

// CreateAccount creates an account with a new sync key and connects. It returns the key,
// which the UI shows once.
func (a *App) CreateAccount(server, invite string) (string, error) {
	u, err := core.ValidateServer(server)
	if err != nil {
		return "", err
	}
	keys := core.GenerateKeys()
	if _, err := core.NewAPI(u, keys).CreateAccount(a.ctx, strings.TrimSpace(invite)); err != nil {
		var h *core.HTTPError
		if errors.As(err, &h) && h.Status == 403 {
			return "", errors.New("The server did not accept the invite token.")
		}
		return "", err
	}
	return keys.Display(), a.finishSetup(u.String(), keys)
}

// Connect connects to an existing account with its sync key.
func (a *App) Connect(server, keyText string) error {
	u, err := core.ValidateServer(server)
	if err != nil {
		return err
	}
	keys, err := core.ParseKeys(keyText)
	if err != nil {
		return errors.New("This is not a valid sync key. Check it for typing errors.")
	}
	if _, err := core.NewAPI(u, keys).AccountInfo(a.ctx); err != nil {
		return err
	}
	return a.finishSetup(u.String(), keys)
}

func (a *App) finishSetup(server string, keys core.Keys) error {
	a.mu.Lock()
	a.closeLocked()
	_ = os.RemoveAll(a.paths.cacheDir())
	a.config.Server = server
	err := writeJSON(a.paths.configFile(), a.config)
	a.mu.Unlock()
	if err != nil {
		return err
	}
	if _, err := saveKey(a.paths, keys.Display()); err != nil {
		return err
	}
	return a.open(server, keys)
}

// Disconnect removes the key and the local cache. Notes stay on the server.
func (a *App) Disconnect() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.closeLocked()
	deleteKey(a.paths)
	a.config.Server = ""
	_ = writeJSON(a.paths.configFile(), a.config)
	return os.RemoveAll(a.paths.cacheDir())
}

// DeleteServerData deletes the account and all data on the server, then disconnects.
func (a *App) DeleteServerData() error {
	_, engine, err := a.current()
	if err != nil {
		return err
	}
	if err := engine.API.DeleteAccount(a.ctx); err != nil {
		return err
	}
	return a.Disconnect()
}

func (a *App) SyncKey() (string, error) {
	store, _, err := a.current()
	if err != nil {
		return "", err
	}
	return store.Keys.Display(), nil
}

func (a *App) SyncNow() {
	if _, engine, err := a.current(); err == nil {
		go engine.Sync()
	}
}

// CleanUpServer deletes attachments on the server that no note uses (older than 24 hours).
func (a *App) CleanUpServer() (int, error) {
	_, engine, err := a.current()
	if err != nil {
		return 0, err
	}
	return engine.RemoveUnusedServerBlobs()
}

// Notes and labels

func (a *App) Notes() ([]core.Note, error) {
	store, _, err := a.current()
	if err != nil {
		return nil, err
	}
	return store.Notes(), nil
}

func (a *App) Labels() ([]core.Label, error) {
	store, _, err := a.current()
	if err != nil {
		return nil, err
	}
	return store.Labels(), nil
}

// NewNote returns an unsaved note; the UI saves it on its first content.
func (a *App) NewNote(typ string) core.Note { return core.NewNote(typ) }

func (a *App) SaveNote(n core.Note) error {
	store, _, err := a.current()
	if err != nil {
		return err
	}
	return store.Save(n)
}

func (a *App) DeleteForever(id string) error {
	store, _, err := a.current()
	if err != nil {
		return err
	}
	return store.DeleteForever(id)
}

func (a *App) EmptyBin() error {
	store, _, err := a.current()
	if err != nil {
		return err
	}
	return store.EmptyBin()
}

func (a *App) Duplicate(id string) (core.Note, error) {
	store, _, err := a.current()
	if err != nil {
		return core.Note{}, err
	}
	return store.Duplicate(id)
}

func (a *App) CreateLabel(value string) error {
	store, _, err := a.current()
	if err != nil {
		return err
	}
	return store.CreateLabel(value)
}

func (a *App) RenameLabel(old, value string) error {
	store, _, err := a.current()
	if err != nil {
		return err
	}
	return store.RenameLabel(old, value)
}

func (a *App) DeleteLabel(value string) error {
	store, _, err := a.current()
	if err != nil {
		return err
	}
	return store.DeleteLabel(value)
}

func (a *App) EditorOpened(id string) {
	if store, _, err := a.current(); err == nil {
		store.EditorOpened(id)
	}
}

func (a *App) EditorClosed(id string) {
	if store, _, err := a.current(); err == nil {
		store.EditorClosed(id)
	}
}

// OpenURL opens a web or mail link in the default browser. Other schemes are refused.
func (a *App) OpenURL(link string) error {
	l := strings.ToLower(strings.TrimSpace(link))
	if !strings.HasPrefix(l, "https://") && !strings.HasPrefix(l, "http://") && !strings.HasPrefix(l, "mailto:") {
		return fmt.Errorf("only web and mail links can be opened")
	}
	wruntime.BrowserOpenURL(a.ctx, strings.TrimSpace(link))
	return nil
}

// Reminders

// reminderLoop shows a notification for each reminder that falls due while the app runs.
func (a *App) reminderLoop(store *core.NoteStore, stop chan struct{}) {
	last := time.Now()
	ticker := time.NewTicker(20 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case now := <-ticker.C:
			for _, n := range core.DueReminders(store.Notes(), last, now) {
				title := n.Title
				if title == "" {
					title = "Reminder"
				}
				body := preview(n)
				if a.notify {
					_ = wruntime.SendNotification(a.ctx, wruntime.NotificationOptions{
						ID: n.ID, Title: title, Body: body, Data: map[string]any{"id": n.ID}})
				}
				wruntime.EventsEmit(a.ctx, "reminder", map[string]string{"id": n.ID, "title": title, "body": body})
			}
			last = now
		}
	}
}

func preview(n core.Note) string {
	text := n.Body
	if n.Type == core.TypeList {
		var items []string
		for _, it := range n.Items {
			if !it.Checked {
				items = append(items, "• "+it.Body)
			}
		}
		text = strings.Join(items, "\n")
	}
	if r := []rune(text); len(r) > 200 {
		text = string(r[:200]) + "…"
	}
	return text
}

// helpers

func readJSON(path string, v any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

func writeJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
