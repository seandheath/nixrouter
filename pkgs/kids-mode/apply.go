// Apply: convert (mode, whitelist) into AGH state and push it.
//
// Restricted: user_rules = ["/.*/", "@@||domain^", ...]; privacy upstreams.
// Play:       user_rules = []; family DNS upstreams.
//
// reconcileLoop runs in the background. It retries on a 30s ticker until
// the first push succeeds (handles the AGH-wizard-not-run-yet case),
// then sits idle until requestReconcile() pokes it.

package main

import (
	"context"
	"time"
)

// Privacy upstreams - normal-everyday Cloudflare/Quad9.
// Used in restricted mode (the rules block almost everything anyway,
// so the upstream barely matters - but a non-filtering upstream
// avoids confusing failures on whitelisted sites).
var privacyUpstreams = []string{
	"1.1.1.1",
	"1.0.0.1",
	"9.9.9.9",
	"8.8.8.8",
}

// Family DNS upstreams - Cloudflare for Families + Quad9 family.
// Used in play mode for defense-in-depth alongside AGH's own filter lists.
var familyUpstreams = []string{
	"1.1.1.3",
	"1.0.0.3",
	"9.9.9.10",
}

// BuildRules turns (mode, whitelist) into the AGH user_rules slice.
//
// Pure function - easy to unit-test and easy to reason about. The
// regex /.*/  matches every hostname; @@||d^ punches a hole for the
// allowed domain and any subdomain.
func BuildRules(mode Mode, whitelist []string) []string {
	if mode != ModeRestricted {
		return []string{}
	}
	rules := make([]string, 0, 1+len(whitelist))
	rules = append(rules, "/.*/")
	for _, d := range whitelist {
		rules = append(rules, "@@||"+d+"^")
	}
	return rules
}

// UpstreamsFor returns the upstream_dns list for the given mode.
func UpstreamsFor(mode Mode) []string {
	if mode == ModePlay {
		return familyUpstreams
	}
	return privacyUpstreams
}

// applyOnce pushes the current desired state to AGH in a single
// best-effort pass. Returns the first error encountered.
func (s *server) applyOnce(ctx context.Context) error {
	mode, err := s.store.Mode()
	if err != nil {
		return err
	}
	whitelist, err := s.store.Whitelist()
	if err != nil {
		return err
	}
	rules := BuildRules(mode, whitelist)
	if err := s.client.SetUserRules(ctx, rules); err != nil {
		return err
	}
	return s.client.SetDNSConfig(ctx, map[string]any{
		"upstream_dns": UpstreamsFor(mode),
	})
}

// reconcileLoop owns the background reconcile. It blocks on the trigger
// channel; tickerC fires periodic refreshes only while the most recent
// apply has failed, so a successful steady state is silent.
func (s *server) reconcileLoop(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		applyCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
		err := s.applyOnce(applyCtx)
		cancel()
		if err == nil {
			s.lastErr.Store(stringPtr(""))
			s.log.Printf("reconcile ok")
		} else {
			s.lastErr.Store(stringPtr(err.Error()))
			s.log.Printf("reconcile failed: %v", err)
		}

		// On success: wait for an explicit trigger (mode/whitelist edit)
		// or a low-frequency safety check.
		// On failure: keep ticking every 30s.
		select {
		case <-ctx.Done():
			return
		case <-s.reconcile:
		case <-ticker.C:
			// If last apply succeeded, skip - nothing changed.
			if last := s.lastErr.Load(); last != nil && *last == "" {
				continue
			}
		}
	}
}

// requestReconcile pokes the loop to re-apply state. Non-blocking.
func (s *server) requestReconcile() {
	select {
	case s.reconcile <- struct{}{}:
	default:
	}
}

// lastError returns the most recent reconcile error message, or "" on
// success / not yet attempted.
func (s *server) lastError() string {
	if v := s.lastErr.Load(); v != nil {
		return *v
	}
	return ""
}

func stringPtr(s string) *string { return &s }
