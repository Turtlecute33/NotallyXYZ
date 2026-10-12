package main

import (
	"sync"
	"time"
)

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
	if now.Sub(l.last) > l.window {
		for k, h := range l.hits {
			if now.After(h.reset) {
				delete(l.hits, k)
			}
		}
		l.last = now
	}
	h, ok := l.hits[ip]
	if !ok || now.After(h.reset) {
		h = &hit{reset: now.Add(l.window)}
		l.hits[ip] = h
	}
	h.count++
}
