package core

import (
	"context"
	"crypto/tls"
	"errors"
	"net/url"
	"os"
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
	retry     time.Duration // wait before the next try after a failed sync; 0 after a full sync
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
	e.cancel() // under e.mu: Sync and StartLive check ctx and add to wg under e.mu
	e.mu.Unlock()
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
	var done bool
	var err error
	for {
		e.runMu.Lock()
		done, err = e.runOnce(e.ctx)
		e.runMu.Unlock()
		if errors.Is(err, context.Canceled) {
			break
		}
		e.setStatus(func(s *SyncStatus) {
			if err != nil {
				s.Error = errorText(err)
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
	// After a failure, or with changes left after conflicts, try again: 5 s, doubling to 5 min.
	e.mu.Lock()
	e.running = false
	if err == nil && done {
		e.retry = 0
	} else {
		e.retry = min(max(2*e.retry, 5*time.Second), 5*time.Minute)
	}
	retry := e.retry
	e.mu.Unlock()
	e.setStatus(func(s *SyncStatus) { s.Syncing = false })
	if retry > 0 {
		e.Schedule(retry)
	}
}

// errorText is the sync error for the UI, without Go internals.
func errorText(err error) string {
	var h *HTTPError
	var u *url.Error
	var cert *tls.CertificateVerificationError
	switch {
	case errors.As(err, &cert):
		return "The certificate of the server is not valid."
	case errors.As(err, &u):
		return "Offline: the server cannot be reached."
	case errors.As(err, &h) && h.Code == "quota_exceeded":
		return "The account on the server is full."
	case errors.As(err, &h) && h.Status >= 500:
		return "The server has a problem. The app tries again later."
	}
	return err.Error()
}

// runOnce runs pull, push and blobs. done is false if local changes are left after conflicts.
func (e *Engine) runOnce(ctx context.Context) (done bool, err error) {
	if err := e.pull(ctx); err != nil {
		return false, err
	}
	var tooLarge error
	conflict := false
	for range 3 {
		// A note over the server limit stays here; the other changes still go.
		if conflict, err = e.push(ctx); errors.Is(err, errTooLarge) {
			tooLarge, err = err, nil
		}
		if err != nil {
			return false, err
		}
		if !conflict {
			break
		}
		if err := e.pull(ctx); err != nil { // conflicts: merge, then push again
			return false, err
		}
	}
	e.downloadMissingBlobs(ctx)
	referenced := e.store.ReferencedBlobIDs()
	if err := e.store.local.Update(func(tx *Tx) error { return tx.PruneBlobs(referenced) }); err != nil {
		return false, err
	}
	return !conflict, tooLarge
}

func (e *Engine) cursor() int64 {
	var cursor int64
	_ = e.store.local.View(func(tx *Tx) error { cursor = tx.Cursor(); return nil })
	return cursor
}

func (e *Engine) pull(ctx context.Context) error {
	for {
		page, err := e.API.Changes(ctx, e.cursor(), 500, 0)
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

// push sends local changes. It reports true if the server reported conflicts, and errTooLarge
// after it sent all other changes if a record is over the server limit.
func (e *Engine) push(ctx context.Context) (bool, error) {
	var dirty, unknown []Record
	held := e.store.heldBack()
	_ = e.store.local.View(func(tx *Tx) error {
		for _, r := range tx.Records() {
			switch {
			case r.Dirty == 0 || (r.Kind == "note" && held[r.ID]):
			case r.Deleted && r.Seq == 0:
				unknown = append(unknown, r)
			case r.Deleted || r.Sealed != nil:
				dirty = append(dirty, r)
			}
		}
		return nil
	})
	// The server never had these records: the deletion is not sent, the row goes.
	if len(unknown) > 0 {
		e.store.mu.Lock()
		err := e.store.local.Update(func(tx *Tx) error {
			for _, r := range unknown {
				if cur := tx.Record(r.Kind, r.ID); cur != nil && cur.Deleted && cur.Seq == 0 {
					if err := tx.DeleteRow(r.Kind, r.ID); err != nil {
						return err
					}
				}
			}
			return nil
		})
		e.store.mu.Unlock()
		if err != nil {
			return false, err
		}
	}
	if len(dirty) == 0 {
		return false, nil
	}
	if err := e.uploadBlobs(ctx, dirty); err != nil {
		return false, err
	}
	conflict, tooLarge := false, false
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
		// The server refuses the whole request for one record over its limit.
		if len(data) > maxRecordBytes {
			tooLarge = true
			continue
		}
		if len(batch) > 0 && (bytes+len(data) > maxBatchBytes || len(batch) >= maxBatchCount) {
			if err := flush(); err != nil {
				return false, err
			}
		}
		batch = append(batch, r)
		out = append(out, OutgoingChange{Kind: r.Kind, ID: r.ID, Base: r.Seq, Data: data})
		bytes += len(data)
	}
	if err := flush(); err != nil {
		return false, err
	}
	if tooLarge {
		return conflict, errTooLarge
	}
	return conflict, nil
}

// uploadBlobs uploads the attachments of the pushed notes that the server does not have: new
// ones, and ones that the clean-up of another device removed. Blobs go up before the notes.
func (e *Engine) uploadBlobs(ctx context.Context, records []Record) error {
	pending := map[string]bool{}
	_ = e.store.local.View(func(tx *Tx) error {
		for _, id := range tx.PendingBlobs() {
			pending[id] = true
		}
		return nil
	})
	var ids []string
	seen := map[string]bool{}
	for _, r := range records {
		n, ok := e.store.Note(r.ID)
		if r.Kind != "note" || r.Deleted || !ok {
			continue
		}
		for _, name := range n.AttachmentNames() {
			if id := e.store.Keys.BlobID(name); !seen[id] && e.store.local.HasBlob(id) {
				seen[id] = true
				ids = append(ids, id)
			}
		}
	}
	for len(ids) > 0 {
		chunk := ids[:min(len(ids), 1000)]
		ids = ids[len(chunk):]
		missing, err := e.API.MissingBlobs(ctx, chunk)
		if err != nil {
			return err
		}
		isMissing := map[string]bool{}
		for _, id := range missing {
			isMissing[id] = true
		}
		var uploaded []string
		for _, id := range chunk {
			if isMissing[id] {
				if err := e.API.PutBlob(ctx, id, e.store.local.BlobPath(id)); err != nil {
					var h *HTTPError
					if !errors.As(err, &h) || h.Status != 413 {
						return err
					}
					continue // larger than the server allows: stays on this device only, and pending
				}
			}
			if pending[id] {
				uploaded = append(uploaded, id)
			}
		}
		if len(uploaded) == 0 {
			continue
		}
		e.store.mu.Lock()
		err = e.store.local.Update(func(tx *Tx) error {
			for _, id := range uploaded {
				if err := tx.MarkUploaded(id); err != nil {
					return err
				}
			}
			return nil
		})
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
		// A blob that does not open is not stored.
		verify := func(path string) error {
			sealed, err := os.ReadFile(path)
			if err == nil {
				_, err = e.store.Keys.Open("blob", id, sealed)
			}
			return err
		}
		if err := e.API.GetBlob(ctx, id, e.store.local.BlobPath(id), verify); err != nil {
			continue // not uploaded yet by the other device, or damaged; retried on the next sync
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
			cursor := e.cursor()
			page, err := e.API.Changes(ctx, cursor, 1, 25)
			progress := err == nil
			if progress && len(page.Changes) > 0 {
				e.Sync()
				// Sync returns at once while another sync runs: wait for that one.
				e.runMu.Lock()
				e.runMu.Unlock()
				progress = e.cursor() != cursor
			}
			if progress {
				delay = 5 * time.Second
				continue
			}
			// An error, or a sync that did not apply the change: wait, else the same poll repeats at once.
			select {
			case <-ctx.Done():
				return
			case <-time.After(delay):
			}
			delay = min(delay*2, 5*time.Minute)
		}
	}()
}

// RemoveUnusedServerBlobs deletes server blobs that no note references and that are older
// than 24 hours, only after a full sync with nothing pending (PROTOCOL.md §6, Blobs).
func (e *Engine) RemoveUnusedServerBlobs() (int, error) {
	ctx := e.ctx
	e.runMu.Lock()
	defer e.runMu.Unlock()
	if _, err := e.runOnce(ctx); err != nil {
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
