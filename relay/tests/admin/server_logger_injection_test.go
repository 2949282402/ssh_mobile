package admin_test

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"

	. "github.com/ssh-mobile/relay/internal/admin"
)

func TestAdminServerWarnsThroughInjectedLogger(t *testing.T) {
	var logs bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&logs, nil))
	server := NewServerWithLogger(Config{
		Address:           ":0",
		TelemetryMySQLDSN: "not-a-mysql-dsn",
		TelemetryRedisURL: "not-a-redis-url",
	}, logger)
	t.Cleanup(func() { _ = server.Close() })

	text := logs.String()
	for _, expected := range []string{
		"telemetry MySQL unavailable",
		"telemetry Redis unavailable",
	} {
		if !strings.Contains(text, expected) {
			t.Fatalf("injected logger output = %q, want it to contain %q", text, expected)
		}
	}
	for _, forbidden := range []string{"not-a-mysql-dsn", "not-a-redis-url"} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("injected logger output = %q, must not contain raw configuration %q", text, forbidden)
		}
	}
}
