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
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// Restricted-mode upstreams - same family-filtering resolvers as play
// mode. The AGH user_rules block almost everything in restricted anyway,
// so the upstream barely matters for the kid's experience - but keeping
// the family list here means any whitelisted site still passes through
// a malware/adult-content filter.
var privacyUpstreams = []string{
	"1.1.1.3",
	"1.0.0.3",
	"9.9.9.10",
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
//
// Side effect: when in restricted mode, also flushes conntrack for the
// Kids VLAN. Cheap and idempotent in the common case (no entries to
// delete) - main effect happens on a play→restricted transition.
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
	if err := s.client.SetDNSConfig(ctx, map[string]any{
		"upstream_dns": UpstreamsFor(mode),
	}); err != nil {
		return err
	}
	if mode == ModeRestricted {
		if ferr := s.flushKidsConntrack(ctx); ferr != nil {
			s.log.Printf("conntrack flush failed (non-fatal): %v", ferr)
		}
	}
	return nil
}

// flushKidsConntrack drops all conntrack entries with source IP in the
// kids subnet. Kills in-flight TCP/UDP sessions immediately, so a kid
// streaming YouTube stops the moment we transition into restricted.
//
// Failure modes (treated as non-fatal):
//   - conntrack binary missing
//   - exit code 1 with "0 flow entries deleted" - normal when there are
//     no matching entries; conntrack returns 1 in that case.
func (s *server) flushKidsConntrack(ctx context.Context) error {
	if s.conntrackPath == "" || s.kidsSubnet == "" {
		return fmt.Errorf("conntrack path or kids subnet not configured")
	}
	cmd := exec.CommandContext(ctx, s.conntrackPath, "-D", "-s", s.kidsSubnet)
	out, err := cmd.CombinedOutput()
	if err != nil {
		// conntrack -D exits 1 when nothing matched. We can't easily
		// distinguish that from other failures by exit code alone, so
		// log the output and return nil unless the binary itself is
		// missing.
		s.log.Printf("conntrack -D -s %s exited %v: %s",
			s.kidsSubnet, err, string(out))
		return nil
	}
	s.log.Printf("conntrack flushed: %s", strings.TrimSpace(string(out)))
	return nil
}

// transitionToRestricted is the canonical play→restricted path. Used
// by both the timer-expiry goroutine and the explicit Restricted click.
func (s *server) transitionToRestricted(ctx context.Context, reason string) {
	s.log.Printf("transition to restricted: %s", reason)
	if err := s.store.SetMode(ModeRestricted); err != nil {
		s.log.Printf("set mode failed: %v", err)
		return
	}
	if err := s.store.ClearPlayUntil(); err != nil {
		s.log.Printf("clear play_until failed: %v", err)
	}
	s.requestReconcile()
}

// expiryLoop transitions to restricted when play_until passes. It also
// recovers from the play-but-no-timer corruption case (treats it as
// expired). Runs every 10 seconds - fine-grained enough for human
// perception, cheap enough to not matter.
func (s *server) expiryLoop(ctx context.Context) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}

		mode, err := s.store.Mode()
		if err != nil {
			s.log.Printf("expiry loop: read mode: %v", err)
			continue
		}
		if mode != ModePlay {
			continue
		}
		until, ok, err := s.store.PlayUntil()
		if err != nil {
			s.log.Printf("expiry loop: read play_until: %v", err)
			continue
		}
		if !ok {
			// Play mode but no timer file - fail safe back to restricted.
			s.transitionToRestricted(ctx, "play mode without play_until - treating as expired")
			continue
		}
		if time.Now().After(until) {
			s.transitionToRestricted(ctx, "timer expired")
		}
	}
}

// NextMidnightLocal returns the next 00:00:00 in the system local
// timezone, strictly after t. Exported so the web handler can use it.
func NextMidnightLocal(t time.Time) time.Time {
	loc := time.Local
	tl := t.In(loc)
	// Today's midnight (start of day) in local time.
	midnight := time.Date(tl.Year(), tl.Month(), tl.Day(), 0, 0, 0, 0, loc)
	// We want the NEXT midnight, which is the start of tomorrow.
	return midnight.AddDate(0, 0, 1)
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
