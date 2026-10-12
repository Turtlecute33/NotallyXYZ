// Command notallyxyz-server is a zero-knowledge sync server for NotallyXYZ.
// It stores only ciphertext. See PROTOCOL.md.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

type config struct {
	listen          string
	dataDir         string
	signupToken     string
	maxBlobBytes    int64
	maxAccountBytes int64
	maxAccounts     int
	trustProxy      bool
}

func loadConfig() (config, error) {
	c := config{
		listen:      env("LISTEN_ADDR", ":8080"),
		dataDir:     env("DATA_DIR", "/data"),
		signupToken: os.Getenv("SIGNUP_TOKEN"),
		trustProxy:  env("TRUST_PROXY", "false") == "true",
	}
	var err error
	if c.maxBlobBytes, err = envMiB("MAX_BLOB_MB", 100); err != nil {
		return c, err
	}
	if c.maxAccountBytes, err = envMiB("MAX_ACCOUNT_MB", 0); err != nil {
		return c, err
	}
	if c.maxAccounts, err = strconv.Atoi(env("MAX_ACCOUNTS", "0")); err != nil || c.maxAccounts < 0 {
		return c, errors.New("MAX_ACCOUNTS must be a number >= 0")
	}
	if c.signupToken != "" && len(c.signupToken) < 16 {
		return c, errors.New("SIGNUP_TOKEN must have at least 16 characters")
	}
	return c, nil
}

func env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func envMiB(key string, def int64) (int64, error) {
	n, err := strconv.ParseInt(env(key, strconv.FormatInt(def, 10)), 10, 64)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("%s must be a number >= 0", key)
	}
	return n << 20, nil
}

func main() {
	healthcheck := flag.Bool("healthcheck", false, "query /v1/health on LISTEN_ADDR and exit")
	flag.Parse()
	log.SetFlags(log.LstdFlags | log.LUTC)

	cfg, err := loadConfig()
	if err != nil {
		log.Fatal(err)
	}
	if *healthcheck {
		os.Exit(runHealthcheck(cfg.listen))
	}

	store, err := openStore(filepath.Join(cfg.dataDir, "notallyxyz.db"), filepath.Join(cfg.dataDir, "blobs"))
	if err != nil {
		log.Fatal(err)
	}
	defer store.Close()

	srv := &http.Server{
		Addr:              cfg.listen,
		Handler:           newAPI(cfg, store).routes(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       90 * time.Second,
		MaxHeaderBytes:    16 << 10,
		ErrorLog:          log.New(os.Stderr, "http: ", log.LstdFlags|log.LUTC),
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		store.wakeAll()
		_ = srv.Shutdown(shutdown)
	}()

	if cfg.signupToken == "" {
		log.Print("signups disabled (SIGNUP_TOKEN not set)")
	}
	log.Printf("listening on %s", cfg.listen)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func runHealthcheck(listen string) int {
	host, port, err := net.SplitHostPort(listen)
	if err != nil {
		return 1
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	client := http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://" + net.JoinHostPort(host, port) + "/v1/health")
	if err != nil {
		return 1
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}
