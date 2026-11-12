package main

import (
	"sync"
	"time"
)

// maxHits bounds the memory of the limiter. When the map is full, a new address is not
// counted: blocking all new addresses would block every client.
const maxHits = 50000

// limiter counts authentication failures per address in memory only.
type limiter struct {
	mu     sync.Mutex
	max    int
	window time.Duration
	hits   map[string]*hit
	last   time.Time
}

type hit struct {
	count int
	reset time.Time
}

func newLimiter(max int, window time.Duration) *limiter {
	return &limiter{max: max, window: window, hits: map[string]*hit{}}
}

func (l *limiter) blocked(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	h, ok := l.hits[ip]
	return ok && h.count >= l.max && time.Now().Before(h.reset)
}

func (l *limiter) fail(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	if now.Sub(l.last) > time.Minute {
		for k, h := range l.hits {
			if now.After(h.reset) {
				delete(l.hits, k)
			}
		}
		l.last = now
	}
	h, ok := l.hits[ip]
	if !ok || now.After(h.reset) {
		if !ok && len(l.hits) >= maxHits {
			return
		}
		h = &hit{reset: now.Add(l.window)}
		l.hits[ip] = h
	}
	h.count++
}
