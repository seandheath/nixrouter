// kids-mode: small HTTP service that flips the Kids VLAN AGH instance
// between "restricted" (whitelist-only) and "play" (block lists +
// family DNS) modes, and lets the user edit the whitelist.
//
// Reconciles desired state to AGH on startup and on every state change,
// retrying in the background until AGH is reachable (handles the
// first-boot case where the AGH wizard hasn't run yet).
package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func main() {
	addr := flag.String("addr", "10.0.0.1:3001", "HTTP listen address")
	stateDir := flag.String("state-dir", "/var/lib/kids-mode", "state directory (mode + whitelist)")
	aghURL := flag.String("agh-url", "http://10.0.0.1:3000", "AdGuard Home base URL")
	credFile := flag.String("agh-credentials-file", "/run/secrets/agh-admin", "file containing user:password for AGH")
	flag.Parse()

	logger := log.New(os.Stderr, "", log.LstdFlags|log.Lmsgprefix)
	logger.SetPrefix("[kids-mode] ")

	creds, err := readCredentials(*credFile)
	if err != nil {
		// Don't refuse to start - the page should still serve a useful
		// status banner so the user can see what's missing. Empty creds
		// will cause every reconcile to fail with 401, which the
		// reconcile loop reports.
		logger.Printf("warning: %v", err)
	}

	client := newAGHClient(*aghURL, creds)
	store, err := newStore(*stateDir)
	if err != nil {
		logger.Fatalf("init state: %v", err)
	}

	srv := &server{
		log:    logger,
		client: client,
		store:  store,
	}

	mux := http.NewServeMux()
	srv.routes(mux)

	httpSrv := &http.Server{
		Addr:              *addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// Start the reconcile loop in the background. It retries every
	// 30s until the first success, then sits idle until something
	// triggers a manual reconcile via srv.requestReconcile().
	go srv.reconcileLoop(ctx)

	// Graceful shutdown.
	go func() {
		<-ctx.Done()
		shutCtx, shutCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutCancel()
		_ = httpSrv.Shutdown(shutCtx)
	}()

	logger.Printf("listening on %s, AGH at %s, state at %s", *addr, *aghURL, *stateDir)
	if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		logger.Fatalf("listen: %v", err)
	}
}

// readCredentials reads a single line of the form "user:password" from path.
// Trailing newlines are trimmed.
func readCredentials(path string) (basicAuth, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return basicAuth{}, err
	}
	line := strings.TrimRight(string(b), "\r\n")
	idx := strings.IndexByte(line, ':')
	if idx <= 0 || idx == len(line)-1 {
		return basicAuth{}, errCreds
	}
	return basicAuth{user: line[:idx], pass: line[idx+1:]}, nil
}
