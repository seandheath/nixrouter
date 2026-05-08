// AdGuard Home HTTP API client.
//
// Auth: HTTP Basic on every request. AGH issues a session cookie via
// POST /control/login but Basic works on every endpoint and is simpler
// for a long-running daemon.
//
// Endpoints used:
//   POST /control/filtering/set_rules  body: {"rules": ["...", ...]}
//   POST /control/dns_config           body: partial DNS config
//   GET  /control/status               health check / readiness probe

package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

var errCreds = errors.New("credentials file must contain user:password on a single line")

type basicAuth struct {
	user string
	pass string
}

func (b basicAuth) header() string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(b.user+":"+b.pass))
}

func (b basicAuth) ok() bool { return b.user != "" && b.pass != "" }

type aghClient struct {
	baseURL string
	auth    basicAuth
	hc      *http.Client
}

func newAGHClient(baseURL string, auth basicAuth) *aghClient {
	return &aghClient{
		baseURL: baseURL,
		auth:    auth,
		hc:      &http.Client{Timeout: 10 * time.Second},
	}
}

// SetUserRules replaces AGH's user_rules with the given slice.
func (c *aghClient) SetUserRules(ctx context.Context, rules []string) error {
	body := map[string][]string{"rules": rules}
	return c.postJSON(ctx, "/control/filtering/set_rules", body)
}

// SetDNSConfig sends a partial DNS config update. Only the keys present
// in the body are updated; AGH merges them onto the live config.
func (c *aghClient) SetDNSConfig(ctx context.Context, partial map[string]any) error {
	return c.postJSON(ctx, "/control/dns_config", partial)
}

// Status returns AGH's /control/status response. Used for readiness checks.
type aghStatus struct {
	Running           bool     `json:"running"`
	ProtectionEnabled bool     `json:"protection_enabled"`
	Version           string   `json:"version"`
	DNSAddresses      []string `json:"dns_addresses"`
	DNSPort           int      `json:"dns_port"`
}

func (c *aghClient) Status(ctx context.Context) (*aghStatus, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+"/control/status", nil)
	if err != nil {
		return nil, err
	}
	if c.auth.ok() {
		req.Header.Set("Authorization", c.auth.header())
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("agh /control/status: %s", resp.Status)
	}
	var s aghStatus
	if err := json.NewDecoder(resp.Body).Decode(&s); err != nil {
		return nil, fmt.Errorf("decode status: %w", err)
	}
	return &s, nil
}

func (c *aghClient) postJSON(ctx context.Context, path string, body any) error {
	buf, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+path, bytes.NewReader(buf))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.auth.ok() {
		req.Header.Set("Authorization", c.auth.header())
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		// Read up to 1KB of body for context in the error.
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return fmt.Errorf("agh %s: %s: %s", path, resp.Status, bytes.TrimSpace(snippet))
	}
	return nil
}
