package admin

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestAdminTelemetryFailClosedNoMySQL verifies that with no TELEMETRY_MYSQL_DSN
// the admin server stays healthy but fails closed on telemetry endpoints
// (503) and never silently falls back to an in-memory store.
func TestAdminTelemetryFailClosedNoMySQL(t *testing.T) {
	server := NewServer(Config{
		Address:   ":0",
		AdminUser: "admin",
		// Config bypasses withConfigDefaults AuthKey random; provide a fixed one.
		AuthKey:       []byte("01234567890123456789012345678901"),
		AdminPassword: "password-over-12-chars",
	})
	defer server.Close()

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	// healthz remains healthy.
	req := httptest.NewRequest(http.MethodGet, PathHealthz, nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected healthz 204, got %d", rec.Code)
	}

	// Auth endpoint must 503 (service unavailable), not fall back to memory.
	authBody, _ := json.Marshal(map[string]any{
		"deviceId": "dev-x",
		"proof":    "beef",
		"expEpoch": 9999999999,
	})
	authReq := httptest.NewRequest(http.MethodPost, "/api/v1/telemetry/auth", bytes.NewReader(authBody))
	authReq.Header.Set("Content-Type", "application/json")
	authRec := httptest.NewRecorder()
	mux.ServeHTTP(authRec, authReq)
	if authRec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 for telemetry auth with no MySQL, got %d", authRec.Code)
	}

	// Ingest endpoint must 503.
	ingestBody, _ := json.Marshal(map[string]any{"records": []any{}})
	ingestReq := httptest.NewRequest(http.MethodPost, "/api/v1/telemetry/ingest", bytes.NewReader(ingestBody))
	ingestReq.Header.Set("Content-Type", "application/json")
	ingestRec := httptest.NewRecorder()
	mux.ServeHTTP(ingestRec, ingestReq)
	if ingestRec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 for telemetry ingest with no MySQL, got %d", ingestRec.Code)
	}
}

// TestAdminTelemetryRegisterDeviceRoute verifies the device enrollment endpoint
// is registered (not 404) and protected by admin auth.
func TestAdminTelemetryRegisterDeviceRoute(t *testing.T) {
	server := NewServer(Config{
		Address:           ":0",
		AdminUser:         "contract-admin",
		AdminPassword:     "password-over-12-chars",
		AuthKey:           []byte("01234567890123456789012345678901"),
		TelemetryMySQLDSN: "",
	})
	defer server.Close()

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	regBody, _ := json.Marshal(map[string]string{"deviceId": "dev-enroll-1"})
	req := httptest.NewRequest(http.MethodPost, "/api/admin/v1/telemetry/devices", bytes.NewReader(regBody))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	// Route exists and is behind admin auth: without a session cookie it must
	// be 401 (auth middleware), not 404 (route missing).
	if rec.Code == http.StatusNotFound {
		t.Fatalf("expected telemetry device route to be registered, got 404")
	}
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 from admin auth middleware for device enrollment, got %d", rec.Code)
	}
}
