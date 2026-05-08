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
	credFile := flag.String("agh-credentials-file", "", "file containing user:password for AGH (empty = no auth)")
	conntrackPath := flag.String("conntrack", "/run/current-system/sw/bin/conntrack",
		"path to the conntrack binary (CAP_NET_ADMIN required to run it usefully)")
	kidsSubnet := flag.String("kids-subnet", "10.20.0.0/24",
		"Kids VLAN CIDR; -s argument for the conntrack flush on play→restricted")
	flag.Parse()

	logger := log.New(os.Stderr, "", log.LstdFlags|log.Lmsgprefix)
	logger.SetPrefix("[kids-mode] ")

	// Empty -agh-credentials-file = no-auth mode. AGH accepts requests
	// without an Authorization header when its `users:` field is empty.
	var creds basicAuth
	if *credFile != "" {
		var err error
		creds, err = readCredentials(*credFile)
		if err != nil {
			logger.Printf("warning: %v", err)
		}
	} else {
		logger.Printf("no AGH credentials configured - sending unauthenticated requests")
	}

	client := newAGHClient(*aghURL, creds)
	store, err := newStore(*stateDir)
	if err != nil {
		logger.Fatalf("init state: %v", err)
	}

	srv := &server{
		log:           logger,
		client:        client,
		store:         store,
		conntrackPath: *conntrackPath,
		kidsSubnet:    *kidsSubnet,
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

	// Watch for play_until expiry; transition to restricted when it passes.
	go srv.expiryLoop(ctx)

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
