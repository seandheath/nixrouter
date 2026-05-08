// State store: mode + whitelist on disk under /var/lib/kids-mode.
//
// Atomic writes (write-to-temp + rename) so a crash mid-update can't
// truncate the file. An in-process mutex serializes RMW.

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

type Mode string

const (
	ModeRestricted Mode = "restricted"
	ModePlay       Mode = "play"
)

func (m Mode) valid() bool { return m == ModeRestricted || m == ModePlay }

type store struct {
	dir string
	mu  sync.Mutex
}

func newStore(dir string) (*store, error) {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, fmt.Errorf("mkdir %s: %w", dir, err)
	}
	s := &store{dir: dir}
	// Default the mode file to "restricted" if missing - safest fallback.
	if _, err := os.Stat(s.modePath()); errors.Is(err, os.ErrNotExist) {
		if err := s.SetMode(ModeRestricted); err != nil {
			return nil, err
		}
	}
	return s, nil
}

func (s *store) modePath() string       { return filepath.Join(s.dir, "mode") }
func (s *store) whitelistPath() string  { return filepath.Join(s.dir, "whitelist.txt") }
func (s *store) playUntilPath() string  { return filepath.Join(s.dir, "play_until") }

func (s *store) Mode() (Mode, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, err := os.ReadFile(s.modePath())
	if err != nil {
		return "", err
	}
	m := Mode(strings.TrimSpace(string(b)))
	if !m.valid() {
		return ModeRestricted, nil
	}
	return m, nil
}

func (s *store) SetMode(m Mode) error {
	if !m.valid() {
		return fmt.Errorf("invalid mode %q", m)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return atomicWrite(s.modePath(), []byte(string(m)+"\n"), 0o640)
}

// Whitelist returns the current allowlist, sorted and deduplicated.
// Missing file = empty list (no error).
func (s *store) Whitelist() ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.readWhitelistLocked()
}

func (s *store) readWhitelistLocked() ([]string, error) {
	b, err := os.ReadFile(s.whitelistPath())
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	return parseWhitelist(string(b)), nil
}

// PlayUntil returns the persisted timer expiry. The bool is false (and t
// is the zero Time) if the file is missing - that's the normal state in
// restricted mode and not an error.
func (s *store) PlayUntil() (time.Time, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, err := os.ReadFile(s.playUntilPath())
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return time.Time{}, false, nil
		}
		return time.Time{}, false, err
	}
	t, err := time.Parse(time.RFC3339, strings.TrimSpace(string(b)))
	if err != nil {
		return time.Time{}, false, fmt.Errorf("parse play_until: %w", err)
	}
	return t, true, nil
}

// SetPlayUntil writes the timer expiry as RFC3339 with timezone info.
func (s *store) SetPlayUntil(t time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return atomicWrite(s.playUntilPath(), []byte(t.Format(time.RFC3339)+"\n"), 0o640)
}

// ClearPlayUntil removes the timer file. Idempotent - missing file is fine.
func (s *store) ClearPlayUntil() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := os.Remove(s.playUntilPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// SetWhitelist replaces the whitelist with a normalized version of the input.
func (s *store) SetWhitelist(raw string) error {
	domains := parseWhitelist(raw)
	s.mu.Lock()
	defer s.mu.Unlock()
	return atomicWrite(s.whitelistPath(), []byte(strings.Join(domains, "\n")+"\n"), 0o640)
}

// parseWhitelist splits on newlines/whitespace, drops blanks and comments,
// lowercases, deduplicates, and returns a sorted slice.
func parseWhitelist(raw string) []string {
	seen := make(map[string]struct{})
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// Take only the first whitespace-separated token in case the
		// user pastes "domain.tld # comment".
		if i := strings.IndexAny(line, " \t"); i >= 0 {
			line = line[:i]
		}
		line = strings.ToLower(line)
		// Strip a leading scheme/protocol if pasted as a URL.
		for _, prefix := range []string{"http://", "https://", "//"} {
			if strings.HasPrefix(line, prefix) {
				line = line[len(prefix):]
				break
			}
		}
		// Drop a trailing path/port.
		if i := strings.IndexAny(line, "/:?"); i >= 0 {
			line = line[:i]
		}
		if line == "" {
			continue
		}
		seen[line] = struct{}{}
	}
	out := make([]string, 0, len(seen))
	for d := range seen {
		out = append(out, d)
	}
	sort.Strings(out)
	return out
}

// atomicWrite writes data to path via a sibling tempfile + rename.
func atomicWrite(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.Remove(tmpName)
		}
	}()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	cleanup = false
	return nil
}
