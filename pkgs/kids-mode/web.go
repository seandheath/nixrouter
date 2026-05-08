// HTTP handlers + the single HTML page.
//
// Routes:
//   GET  /            - render the page
//   POST /toggle      - flip mode (form submit), redirect to /
//   POST /whitelist   - replace whitelist (form submit), redirect to /
//   GET  /healthz     - readiness probe (200 if state dir is readable)

package main

import (
	_ "embed"
	"html/template"
	"log"
	"net/http"
	"strings"
	"sync/atomic"
)

//go:embed index.html
var indexHTMLRaw string

var indexTmpl = template.Must(template.New("index").Parse(indexHTMLRaw))

type server struct {
	log       *log.Logger
	client    *aghClient
	store     *store
	reconcile chan struct{}
	lastErr   atomic.Pointer[string]
}

// init the channel lazily on first routes() call so the zero-value
// server is still usable in tests.
func (s *server) routes(mux *http.ServeMux) {
	if s.reconcile == nil {
		s.reconcile = make(chan struct{}, 1)
	}
	mux.HandleFunc("/", s.handleIndex)
	mux.HandleFunc("/toggle", s.handleToggle)
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
	Mode      Mode
	Whitelist string
	LastError string
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
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := indexTmpl.Execute(w, data); err != nil {
		s.log.Printf("template execute: %v", err)
	}
}

func (s *server) handleToggle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	requested := Mode(r.FormValue("mode"))
	if !requested.valid() {
		http.Error(w, "invalid mode", http.StatusBadRequest)
		return
	}
	if err := s.store.SetMode(requested); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	s.log.Printf("mode set to %s", requested)
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
