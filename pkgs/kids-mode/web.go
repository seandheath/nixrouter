// HTTP handlers + the single HTML page.
//
// Routes:
//   GET  /            - render the page
//   POST /toggle      - flip to restricted (form submit), redirect to /
//   POST /play        - enter play mode with a timer (duration or until=midnight)
//   POST /whitelist   - replace whitelist (form submit), redirect to /
//   GET  /healthz     - readiness probe (200 if state dir is readable)

package main

import (
	_ "embed"
	"html/template"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

//go:embed index.html
var indexHTMLRaw string

var indexTmpl = template.Must(template.New("index").Parse(indexHTMLRaw))

type server struct {
	log           *log.Logger
	client        *aghClient
	store         *store
	conntrackPath string
	kidsSubnet    string
	reconcile     chan struct{}
	lastErr       atomic.Pointer[string]
}

// init the channel lazily on first routes() call so the zero-value
// server is still usable in tests.
func (s *server) routes(mux *http.ServeMux) {
	if s.reconcile == nil {
		s.reconcile = make(chan struct{}, 1)
	}
	mux.HandleFunc("/", s.handleIndex)
	mux.HandleFunc("/toggle", s.handleToggle)
	mux.HandleFunc("/play", s.handlePlay)
	mux.HandleFunc("/whitelist", s.handleWhitelist)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if _, err := s.store.Mode(); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		_, _ = w.Write([]byte("ok\n"))
	})
}

type pageData struct {
	Mode                 Mode
	Whitelist            string
	LastError            string
	PlayRemainingMinutes int
	PlayUntilLocal       string
}

func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	mode, err := s.store.Mode()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	whitelist, err := s.store.Whitelist()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	data := pageData{
		Mode:      mode,
		Whitelist: strings.Join(whitelist, "\n"),
		LastError: s.lastError(),
	}
	if mode == ModePlay {
		until, ok, err := s.store.PlayUntil()
		if err != nil {
			s.log.Printf("read play_until: %v", err)
		} else if ok {
			remaining := time.Until(until)
			if remaining < 0 {
				remaining = 0
			}
			// Round up so a half-minute remaining shows as 1, not 0.
			data.PlayRemainingMinutes = int((remaining + time.Minute - 1) / time.Minute)
			data.PlayUntilLocal = until.In(time.Local).Format("Mon 3:04 PM")
		}
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := indexTmpl.Execute(w, data); err != nil {
		s.log.Printf("template execute: %v", err)
	}
}

// handleToggle is now restricted-only. Play activations go through /play.
func (s *server) handleToggle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if Mode(r.FormValue("mode")) != ModeRestricted {
		http.Error(w, "/toggle only accepts mode=restricted - use /play to enter play mode", http.StatusBadRequest)
		return
	}
	s.transitionToRestricted(r.Context(), "manual restricted")
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// handlePlay enters play mode with an expiry. Two input shapes:
//   - minutes=N    : extend - new expiry = max(now, current expiry) + N minutes
//   - until=midnight : replace - new expiry = next local midnight
func (s *server) handlePlay(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	now := time.Now()
	var newUntil time.Time

	if r.FormValue("until") == "midnight" {
		newUntil = NextMidnightLocal(now)
	} else {
		mins, err := strconv.Atoi(r.FormValue("minutes"))
		if err != nil || mins < 1 || mins > 1440 {
			http.Error(w, "minutes must be an integer between 1 and 1440", http.StatusBadRequest)
			return
		}
		// Extend semantics: pile new minutes on top of any existing future expiry.
		base := now
		if cur, ok, _ := s.store.PlayUntil(); ok && cur.After(now) {
			base = cur
		}
		newUntil = base.Add(time.Duration(mins) * time.Minute)
	}

	if err := s.store.SetMode(ModePlay); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if err := s.store.SetPlayUntil(newUntil); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	s.log.Printf("play mode set, expires %s", newUntil.In(time.Local).Format(time.RFC3339))
	s.requestReconcile()
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (s *server) handleWhitelist(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	// Body limited to 256KB - way more than a sensible whitelist.
	r.Body = http.MaxBytesReader(w, r.Body, 256*1024)
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := s.store.SetWhitelist(r.FormValue("whitelist")); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	s.log.Printf("whitelist updated")
	s.requestReconcile()
	http.Redirect(w, r, "/", http.StatusSeeOther)
}
