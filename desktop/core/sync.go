package core

import (
	"context"
	"errors"
	"sync"
	"time"
)

// SyncStatus is shown in the UI.
type SyncStatus struct {
	Syncing  bool   `json:"syncing"`
	LastSync int64  `json:"lastSync"` // ms, 0 = never
	Error    string `json:"error"`
}

// Engine runs pull, push, blobs and live updates (PROTOCOL.md §6–7).
type Engine struct {
	API   *API
	store *NoteStore

	mu        sync.Mutex
	runMu     sync.Mutex // one runOnce at a time
	status    SyncStatus
	running   bool
	again     bool
	scheduled *time.Timer
	liveStop  context.CancelFunc
	ctx       context.Context
	cancel    context.CancelFunc
	wg        sync.WaitGroup

	// OnStatus runs after the status changed.
	OnStatus func(SyncStatus)
}

const (
	maxBatchBytes = 16 << 20
	maxBatchCount = 200
)

func NewEngine(store *NoteStore, api *API) *Engine {
	ctx, cancel := context.WithCancel(context.Background())
	return &Engine{API: api, store: store, ctx: ctx, cancel: cancel}
}

func (e *Engine) Status() SyncStatus {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.status
}

func (e *Engine) setStatus(fn func(*SyncStatus)) {
	e.mu.Lock()
	fn(&e.status)
	st := e.status
	e.mu.Unlock()
	if e.OnStatus != nil {
		e.OnStatus(st)
	}
}

// Stop cancels all network work and waits for it.
func (e *Engine) Stop() {
	e.mu.Lock()
	if e.scheduled != nil {
		e.scheduled.Stop()
	}
	e.mu.Unlock()
	e.cancel()
	e.wg.Wait()
}

// Schedule runs a sync after a short pause (debounced local edits).
func (e *Engine) Schedule(after time.Duration) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.ctx.Err() != nil {
		return
	}
	if e.scheduled != nil {
		e.scheduled.Stop()
	}
	e.scheduled = time.AfterFunc(after, func() { e.Sync() })
}

// Sync runs one sync; a call during a sync runs it again afterwards.
func (e *Engine) Sync() {
	e.mu.Lock()
	if e.running {
		e.again = true
		e.mu.Unlock()
		return
	}
	if e.ctx.Err() != nil {
		e.mu.Unlock()
		return
	}
	e.running = true
	e.wg.Add(1)
	e.mu.Unlock()
	defer e.wg.Done()
	e.setStatus(func(s *SyncStatus) { s.Syncing = true })
	for {
		e.runMu.Lock()
		err := e.runOnce(e.ctx)
		e.runMu.Unlock()
		if errors.Is(err, context.Canceled) {
			break
		}
		e.setStatus(func(s *SyncStatus) {
			if err != nil {
				s.Error = err.Error()
			} else {
				s.Error, s.LastSync = "", Now()
			}
		})
		e.mu.Lock()
		again := e.again
		e.again = false
		e.mu.Unlock()
		if !again {
			break
		}
	}
	e.mu.Lock()
	e.running = false
	e.mu.Unlock()
	e.setStatus(func(s *SyncStatus) { s.Syncing = false })
}

func (e *Engine) runOnce(ctx context.Context) error {
	if err := e.pull(ctx); err != nil {
		return err
	}
	for range 3 {
		conflict, err := e.push(ctx)
		if err != nil {
			return err
		}
		if !conflict {
			break
		}
		if err := e.pull(ctx); err != nil { // conflicts: merge, then push again
			return err
		}
	}
	e.downloadMissingBlobs(ctx)
	referenced := e.store.ReferencedBlobIDs()
	return e.store.local.Update(func(tx *Tx) error { return tx.PruneBlobs(referenced) })
}

func (e *Engine) pull(ctx context.Context) error {
	for {
		var cursor int64
		_ = e.store.local.View(func(tx *Tx) error { cursor = tx.Cursor(); return nil })
		page, err := e.API.Changes(ctx, cursor, 500, 0)
		if err != nil {
			return err
		}
		if err := e.store.ApplyRemote(page.Changes, page.Seq); err != nil {
			return err
		}
		if !page.More {
			return nil
		}
	}
}

// push sends local changes. It reports true if the server reported conflicts.
func (e *Engine) push(ctx context.Context) (bool, error) {
	var dirty []Record
	held := e.store.heldBack()
	_ = e.store.local.View(func(tx *Tx) error {
		for _, r := range tx.Records() {
			if r.Dirty > 0 && !(r.Kind == "note" && held[r.ID]) && (r.Deleted || r.Sealed != nil) {
				dirty = append(dirty, r)
			}
		}
		return nil
	})
	if len(dirty) == 0 {
		return false, nil
	}
	if err := e.uploadPendingBlobs(ctx); err != nil {
		return false, err
	}
	conflict := false
	var batch []Record
	var out []OutgoingChange
	bytes := 0
	flush := func() error {
		if len(batch) == 0 {
			return nil
		}
		results, err := e.API.Push(ctx, out)
		if err != nil {
			return err
		}
		sent := batch
		batch, out, bytes = nil, nil, 0
		e.store.mu.Lock()
		defer e.store.mu.Unlock()
		return e.store.local.Update(func(tx *Tx) error {
			for _, res := range results {
				for _, r := range sent {
					if r.Kind != res.Kind || r.ID != res.ID {
						continue
					}
					if res.Conflict {
						conflict = true
					} else if err := tx.MarkPushed(r.Kind, r.ID, res.Seq, r.Dirty, r.Sealed); err != nil {
						return err
					}
				}
			}
			return nil
		})
	}
	for _, r := range dirty {
		// A deletion carries a sealed tombstone, so that the server cannot fake one.
		data := r.Sealed
		if r.Deleted {
			data = e.store.Keys.Seal(r.Kind, r.ID, tombstone)
		}
		if len(batch) > 0 && (bytes+len(data) > maxBatchBytes || len(batch) >= maxBatchCount) {
			if err := flush(); err != nil {
				return false, err
			}
		}
		batch = append(batch, r)
		out = append(out, OutgoingChange{Kind: r.Kind, ID: r.ID, Base: r.Seq, Deleted: r.Deleted, Data: data})
		bytes += len(data)
	}
	return conflict, flush()
}

// uploadPendingBlobs: blobs go up before the notes that reference them.
func (e *Engine) uploadPendingBlobs(ctx context.Context) error {
	var pending []string
	_ = e.store.local.View(func(tx *Tx) error { pending = tx.PendingBlobs(); return nil })
	var present []string
	for _, id := range pending {
		if e.store.local.HasBlob(id) {
			present = append(present, id)
		}
	}
	if len(present) == 0 {
		return nil
	}
	missing, err := e.API.MissingBlobs(ctx, present)
	if err != nil {
		return err
	}
	isMissing := map[string]bool{}
	for _, id := range missing {
		isMissing[id] = true
	}
	for _, id := range present {
		if isMissing[id] {
			if err := e.API.PutBlob(ctx, id, e.store.local.BlobPath(id)); err != nil {
				var h *HTTPError
				if !errors.As(err, &h) || h.Status != 413 {
					return err
				}
				// Larger than the server allows: stays on this device only.
			}
		}
		e.store.mu.Lock()
		err := e.store.local.Update(func(tx *Tx) error { return tx.MarkUploaded(id) })
		e.store.mu.Unlock()
		if err != nil {
			return err
		}
	}
	return nil
}

func (e *Engine) downloadMissingBlobs(ctx context.Context) {
	downloaded := false
	for id := range e.store.ReferencedBlobIDs() {
		if e.store.local.HasBlob(id) {
			continue
		}
		if err := e.API.GetBlob(ctx, id, e.store.local.BlobPath(id)); err != nil {
			continue // not uploaded yet by the other device; retried on the next sync
		}
		e.store.mu.Lock()
		_ = e.store.local.Update(func(tx *Tx) error { return tx.AddBlob(id, true) })
		e.store.mu.Unlock()
		downloaded = true
	}
	if downloaded {
		e.store.emit(false)
	}
}

// StartLive long-polls for changes while the app runs. Backs off on errors.
func (e *Engine) StartLive() {
	e.mu.Lock()
	if e.liveStop != nil || e.ctx.Err() != nil {
		e.mu.Unlock()
		return
	}
	ctx, stop := context.WithCancel(e.ctx)
	e.liveStop = stop
	e.wg.Add(1)
	e.mu.Unlock()
	go func() {
		defer e.wg.Done()
		delay := 5 * time.Second
		for ctx.Err() == nil {
			var cursor int64
			_ = e.store.local.View(func(tx *Tx) error { cursor = tx.Cursor(); return nil })
			page, err := e.API.Changes(ctx, cursor, 1, 25)
			if err != nil {
				select {
				case <-ctx.Done():
					return
				case <-time.After(delay):
				}
				delay = min(delay*2, 5*time.Minute)
				continue
			}
			delay = 5 * time.Second
			if len(page.Changes) > 0 {
				e.Sync()
			}
		}
	}()
}

// RemoveUnusedServerBlobs deletes server blobs that no note references and that are older
// than 24 hours, only after a full sync with nothing pending (PROTOCOL.md §6, Blobs).
func (e *Engine) RemoveUnusedServerBlobs() (int, error) {
	ctx := e.ctx
	e.runMu.Lock()
	defer e.runMu.Unlock()
	if err := e.runOnce(ctx); err != nil {
		return 0, err
	}
	pending := false
	_ = e.store.local.View(func(tx *Tx) error {
		for _, r := range tx.Records() {
			pending = pending || r.Dirty > 0
		}
		return nil
	})
	if pending {
		return 0, nil
	}
	referenced := e.store.ReferencedBlobIDs()
	cutoff := time.Now().Unix() - 24*3600
	blobs, err := e.API.ListBlobs(ctx)
	if err != nil {
		return 0, err
	}
	removed := 0
	for _, b := range blobs {
		if !referenced[b.ID] && b.Created < cutoff {
			if err := e.API.DeleteBlob(ctx, b.ID); err != nil {
				return removed, err
			}
			removed++
		}
	}
	return removed, nil
}
