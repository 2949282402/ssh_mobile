package admin_test

import (
	"bytes"
	"encoding/base64"
	"strings"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/admin"
)

func clearAdminEnvironment(t *testing.T) {
	t.Helper()
	for _, name := range []string{
		"ADMIN_ADDR", "ADMIN_USER", "ADMIN_PASSWORD", "ADMIN_AUTH_KEY", "ADMIN_RELAY_URL",
		"ADMIN_RELAY_INTERNAL_TOKEN", "ADMIN_SESSION_TTL", "ADMIN_MAX_SESSIONS",
		"ADMIN_LOGIN_MAX_ATTEMPTS", "ADMIN_LOGIN_WINDOW", "ADMIN_LOGIN_BLOCK", "ADMIN_MAX_LOGIN_ENTRIES",
		"ADMIN_TRUSTED_PROXY_CIDRS", "ADMIN_HTTP_READ_TIMEOUT", "ADMIN_HTTP_WRITE_TIMEOUT",
		"ADMIN_HTTP_IDLE_TIMEOUT", "ADMIN_HTTP_MAX_HEADER_BYTES", "TELEMETRY_MYSQL_DSN",
		"TELEMETRY_REDIS_URL", "TELEMETRY_AUTH_SECRET", "TELEMETRY_MAX_BODY_BYTES",
		"TELEMETRY_MAX_BATCH_SIZE", "TELEMETRY_MAX_CONCURRENT_WRITERS",
		"TELEMETRY_RATE_LIMIT_CAPACITY", "TELEMETRY_RATE_LIMIT_REFILL_PER_SECOND",
		"TELEMETRY_RATE_LIMIT_MAX_DEVICES", "TELEMETRY_RATE_LIMIT_DEVICE_TTL",
		"TELEMETRY_RETRY_AFTER_SECONDS",
	} {
		t.Setenv(name, "")
	}
}

func setValidAdminEnvironment(t *testing.T) {
	t.Helper()
	clearAdminEnvironment(t)
	t.Setenv("ADMIN_USER", "operations")
	t.Setenv("ADMIN_PASSWORD", "a-password-longer-than-twelve")
	t.Setenv("ADMIN_AUTH_KEY", base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x42}, 32)))
	t.Setenv("ADMIN_RELAY_INTERNAL_TOKEN", "relay-internal-token-with-32-bytes")
}

func TestConfigFromEnvironmentUsesSafeDefaults(t *testing.T) {
	setValidAdminEnvironment(t)

	config, err := ConfigFromEnvironment()
	if err != nil {
		t.Fatalf("ConfigFromEnvironment failed: %v", err)
	}
	if config.Address != ":8081" || config.RelayURL != "http://relay:8080" {
		t.Fatalf("unexpected default endpoints: address=%q relay=%q", config.Address, config.RelayURL)
	}
	if config.SessionTTL != 24*time.Hour || config.MaxSessions != 32 || config.LoginMaxAttempts != 5 || config.MaxLoginEntries != 4096 {
		t.Fatalf("unexpected admin defaults: %+v", config)
	}
	if config.LoginWindow != time.Minute || config.LoginBlockDuration != 5*time.Minute {
		t.Fatalf("unexpected login defaults: window=%v block=%v", config.LoginWindow, config.LoginBlockDuration)
	}
	if config.HTTPReadTimeout != 15*time.Second || config.HTTPWriteTimeout != 15*time.Second || config.HTTPIdleTimeout != time.Minute || config.HTTPMaxHeaderBytes != 16*1024 {
		t.Fatalf("unexpected HTTP defaults: read=%v write=%v idle=%v headers=%d", config.HTTPReadTimeout, config.HTTPWriteTimeout, config.HTTPIdleTimeout, config.HTTPMaxHeaderBytes)
	}
	if config.TrustedProxyCIDRs != nil || config.TelemetryMySQLDSN != "" || config.TelemetryRedisURL != "" || config.TelemetryAuthSecret != "" {
		t.Fatalf("unexpected optional defaults: %+v", config)
	}
}

func TestConfigFromEnvironmentReadsCustomLimitsAndProxyAddresses(t *testing.T) {
	setValidAdminEnvironment(t)
	for name, value := range map[string]string{
		"ADMIN_ADDR":                             "127.0.0.1:18081",
		"ADMIN_RELAY_URL":                        "https://relay.example.test/base",
		"ADMIN_SESSION_TTL":                      "2h",
		"ADMIN_MAX_SESSIONS":                     "7",
		"ADMIN_LOGIN_MAX_ATTEMPTS":               "8",
		"ADMIN_LOGIN_WINDOW":                     "90s",
		"ADMIN_LOGIN_BLOCK":                      "3m",
		"ADMIN_MAX_LOGIN_ENTRIES":                "99",
		"ADMIN_TRUSTED_PROXY_CIDRS":              "10.0.0.0/8, 192.0.2.7, invalid, , 2001:db8::/32",
		"ADMIN_HTTP_READ_TIMEOUT":                "11s",
		"ADMIN_HTTP_WRITE_TIMEOUT":               "12s",
		"ADMIN_HTTP_IDLE_TIMEOUT":                "13s",
		"ADMIN_HTTP_MAX_HEADER_BYTES":            "8192",
		"TELEMETRY_MYSQL_DSN":                    "  mysql-dsn  ",
		"TELEMETRY_REDIS_URL":                    "  redis-url  ",
		"TELEMETRY_AUTH_SECRET":                  "  telemetry-secret  ",
		"TELEMETRY_MAX_BODY_BYTES":               "2048",
		"TELEMETRY_MAX_BATCH_SIZE":               "9",
		"TELEMETRY_MAX_CONCURRENT_WRITERS":       "8",
		"TELEMETRY_RATE_LIMIT_CAPACITY":          "3",
		"TELEMETRY_RATE_LIMIT_REFILL_PER_SECOND": "2.5",
		"TELEMETRY_RATE_LIMIT_MAX_DEVICES":       "7",
		"TELEMETRY_RATE_LIMIT_DEVICE_TTL":        "2m",
		"TELEMETRY_RETRY_AFTER_SECONDS":          "4",
	} {
		t.Setenv(name, value)
	}

	config, err := ConfigFromEnvironment()
	if err != nil {
		t.Fatalf("ConfigFromEnvironment failed: %v", err)
	}
	if config.Address != "127.0.0.1:18081" || config.RelayURL != "https://relay.example.test/base" || config.SessionTTL != 2*time.Hour || config.MaxSessions != 7 {
		t.Fatalf("custom admin values not retained: %+v", config)
	}
	if len(config.TrustedProxyCIDRs) != 3 || config.TrustedProxyCIDRs[1].String() != "192.0.2.7/32" {
		t.Fatalf("unexpected trusted proxies: %v", config.TrustedProxyCIDRs)
	}
	if config.TelemetryMySQLDSN != "mysql-dsn" || config.TelemetryRedisURL != "redis-url" || config.TelemetryAuthSecret != "telemetry-secret" {
		t.Fatalf("telemetry connection values were not trimmed: %+v", config)
	}
	ingest := config.TelemetryIngest
	if ingest.MaxBodyBytes != 2048 || ingest.MaxBatchSize != 9 || ingest.MaxConcurrentWriters != 8 || ingest.RateLimitCapacity != 3 || ingest.RateLimitRefillPerSecond != 2.5 || ingest.RateLimitMaxDevices != 7 || ingest.RateLimitDeviceTTL != 2*time.Minute || ingest.RetryAfterSeconds != 4 {
		t.Fatalf("custom ingest values not retained: %+v", ingest)
	}
}

func TestConfigFromEnvironmentRejectsInvalidRequiredValues(t *testing.T) {
	tests := []struct {
		name  string
		set   func(*testing.T)
		match string
	}{
		{"missing user", func(t *testing.T) { t.Setenv("ADMIN_USER", "") }, "ADMIN_USER"},
		{"published user example", func(t *testing.T) { t.Setenv("ADMIN_USER", "replace-with-an-admin-username") }, "ADMIN_USER"},
		{"short password", func(t *testing.T) { t.Setenv("ADMIN_PASSWORD", "too-short") }, "ADMIN_PASSWORD"},
		{"published password example", func(t *testing.T) {
			t.Setenv("ADMIN_PASSWORD", "replace-with-a-random-password-of-at-least-12-characters")
		}, "ADMIN_PASSWORD"},
		{"missing auth key", func(t *testing.T) { t.Setenv("ADMIN_AUTH_KEY", "") }, "ADMIN_AUTH_KEY"},
		{"invalid auth key", func(t *testing.T) { t.Setenv("ADMIN_AUTH_KEY", "not-base64") }, "ADMIN_AUTH_KEY"},
		{"short auth key", func(t *testing.T) {
			t.Setenv("ADMIN_AUTH_KEY", base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 31)))
		}, "ADMIN_AUTH_KEY"},
		{"invalid relay URL", func(t *testing.T) { t.Setenv("ADMIN_RELAY_URL", "not-a-url") }, "ADMIN_RELAY_URL"},
		{"unsupported relay URL", func(t *testing.T) { t.Setenv("ADMIN_RELAY_URL", "ftp://relay.example.test") }, "ADMIN_RELAY_URL"},
		{"relay URL without host", func(t *testing.T) { t.Setenv("ADMIN_RELAY_URL", "http://") }, "ADMIN_RELAY_URL"},
		{"short internal token", func(t *testing.T) { t.Setenv("ADMIN_RELAY_INTERNAL_TOKEN", "short-token") }, "ADMIN_RELAY_INTERNAL_TOKEN"},
		{"published internal token example", func(t *testing.T) {
			t.Setenv("ADMIN_RELAY_INTERNAL_TOKEN", "replace-with-a-32-byte-random-internal-token")
		}, "ADMIN_RELAY_INTERNAL_TOKEN"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			setValidAdminEnvironment(t)
			tc.set(t)
			if _, err := ConfigFromEnvironment(); err == nil || !strings.Contains(err.Error(), tc.match) {
				t.Fatalf("error = %v, want message containing %q", err, tc.match)
			}
		})
	}
}

func TestConfigFromEnvironmentRejectsInvalidLimits(t *testing.T) {
	tests := []struct {
		name string
		set  func(*testing.T)
		want string
	}{
		{"admin duration", func(t *testing.T) { t.Setenv("ADMIN_SESSION_TTL", "later") }, "ADMIN_SESSION_TTL"},
		{"admin integer", func(t *testing.T) { t.Setenv("ADMIN_MAX_SESSIONS", "0") }, "ADMIN_MAX_SESSIONS"},
		{"telemetry integer", func(t *testing.T) { t.Setenv("TELEMETRY_MAX_BATCH_SIZE", "-1") }, "TELEMETRY_MAX_BATCH_SIZE"},
		{"telemetry number", func(t *testing.T) { t.Setenv("TELEMETRY_RATE_LIMIT_REFILL_PER_SECOND", "NaN") }, "TELEMETRY_RATE_LIMIT_REFILL_PER_SECOND"},
		{"telemetry duration", func(t *testing.T) { t.Setenv("TELEMETRY_RATE_LIMIT_DEVICE_TTL", "zero") }, "TELEMETRY_RATE_LIMIT_DEVICE_TTL"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			setValidAdminEnvironment(t)
			tc.set(t)
			if _, err := ConfigFromEnvironment(); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error = %v, want message containing %q", err, tc.want)
			}
		})
	}
}
