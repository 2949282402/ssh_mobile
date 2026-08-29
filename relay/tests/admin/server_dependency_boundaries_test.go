package admin_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	. "github.com/ssh-mobile/relay/internal/admin"
)

func TestAdminTelemetryDependenciesFailClosedAndKeepLiveness(t *testing.T) {
	server := NewServer(Config{
		Address:           ":0",
		AdminUser:         "admin",
		AdminPassword:     "password-long-enough",
		AuthKey:           []byte("0123456789abcdef0123456789abcdef"),
		TelemetryMySQLDSN: "not-a-mysql-dsn",
		TelemetryRedisURL: "not-a-redis-url",
	})
	t.Cleanup(func() { _ = server.Close() })
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	health := httptest.NewRecorder()
	mux.ServeHTTP(health, httptest.NewRequest(http.MethodGet, PathHealthz, nil))
	if health.Code != http.StatusNoContent {
		t.Fatalf("health status = %d, want 204", health.Code)
	}

	// An invalid MySQL endpoint leaves telemetry unavailable rather than
	// silently selecting a process-local persistence store. An invalid Redis
	// URL is likewise degraded to the documented no-op cache.
	telemetry := httptest.NewRecorder()
	mux.ServeHTTP(telemetry, httptest.NewRequest(http.MethodGet, "/api/admin/v1/telemetry/overview", nil))
	if telemetry.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated telemetry status = %d, want 401", telemetry.Code)
	}
	cookie := adminLoginCookie(t, mux)
	telemetry = httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/admin/v1/telemetry/overview", nil)
	request.AddCookie(cookie)
	mux.ServeHTTP(telemetry, request)
	if telemetry.Code != http.StatusServiceUnavailable {
		t.Fatalf("telemetry status with invalid MySQL = %d, want 503", telemetry.Code)
	}
}
