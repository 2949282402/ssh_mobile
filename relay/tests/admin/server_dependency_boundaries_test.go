package admin_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	. "github.com/ssh-mobile/relay/internal/admin"
	telemetrypkg "github.com/ssh-mobile/relay/internal/telemetry"
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

func TestAdminTelemetryStaysLiveWithUnavailableRedisAndRealMySQL(t *testing.T) {
	dsn := os.Getenv("TELEMETRY_TEST_MYSQL_DSN")
	if dsn == "" {
		t.Skip("TELEMETRY_TEST_MYSQL_DSN is not set; skipping MySQL-backed Redis outage regression")
	}

	server := NewServer(Config{
		Address:             ":0",
		AdminUser:           "admin",
		AdminPassword:       "password-long-enough",
		AuthKey:             []byte("0123456789abcdef0123456789abcdef"),
		TelemetryMySQLDSN:   dsn,
		TelemetryRedisURL:   "redis://127.0.0.1:1/0",
		TelemetryAuthSecret: "telemetry-auth-secret-long-enough",
	})
	t.Cleanup(func() { _ = server.Close() })
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	health := httptest.NewRecorder()
	mux.ServeHTTP(health, httptest.NewRequest(http.MethodGet, PathHealthz, nil))
	if health.Code != http.StatusNoContent {
		t.Fatalf("health status with unavailable Redis = %d, want 204", health.Code)
	}

	cookie := adminLoginCookie(t, mux)
	overview := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, telemetrypkg.PathAdminOverview, nil)
	request.AddCookie(cookie)
	mux.ServeHTTP(overview, request)
	if overview.Code != http.StatusOK {
		t.Fatalf("telemetry overview with unavailable Redis = %d, want 200: %s", overview.Code, overview.Body.String())
	}
	var response struct {
		PipelineHealth struct {
			Status           string `json:"status"`
			RedisCacheStatus string `json:"redisCacheStatus"`
		} `json:"pipelineHealth"`
	}
	if err := json.NewDecoder(overview.Body).Decode(&response); err != nil {
		t.Fatalf("decode telemetry overview: %v", err)
	}
	if response.PipelineHealth.Status != "degraded" || response.PipelineHealth.RedisCacheStatus != "fallback_mysql" {
		t.Fatalf("pipeline health = %+v, want degraded/fallback_mysql", response.PipelineHealth)
	}
}
