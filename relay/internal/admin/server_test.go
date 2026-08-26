package admin

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestAdminServerHealthz(t *testing.T) {
	server := NewServer(Config{
		Address: ":8081",
	})
	defer server.Close()

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("healthz status = %d, want 204", rec.Code)
	}
	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("healthz Cache-Control = %q, want 'no-store'", rec.Header().Get("Cache-Control"))
	}
}

func TestAdminConfigDefaults(t *testing.T) {
	cfg := withConfigDefaults(Config{})
	if cfg.Address != ":8081" {
		t.Fatalf("default address = %q, want :8081", cfg.Address)
	}
	if cfg.SessionTTL != 24*time.Hour {
		t.Fatalf("default session TTL = %v, want 24h", cfg.SessionTTL)
	}
	if cfg.MaxSessions != 32 {
		t.Fatalf("default max sessions = %d, want 32", cfg.MaxSessions)
	}
	if cfg.HTTPReadTimeout != 15*time.Second {
		t.Fatalf("default read timeout = %v, want 15s", cfg.HTTPReadTimeout)
	}
}
