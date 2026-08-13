package relay

import (
	"testing"
	"time"
)

func TestConfigRequiresExplicitSecretsAndAdministrator(t *testing.T) {
	t.Setenv("RELAY_ADDR", ":9090")
	t.Setenv("RELAY_ENROLLMENT_TOKEN", "0123456789abcdef")
	t.Setenv(
		"RELAY_CREDENTIAL_KEY",
		"MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE",
	)
	t.Setenv("RELAY_ADMIN_USER", "")
	t.Setenv("RELAY_ADMIN_PASSWORD", "")
	if _, err := ConfigFromEnvironment(); err == nil {
		t.Fatal("missing administrator credentials were accepted")
	}

	t.Setenv("RELAY_ADMIN_USER", "admin")
	t.Setenv("RELAY_ADMIN_PASSWORD", "short")
	if _, err := ConfigFromEnvironment(); err == nil {
		t.Fatal("short administrator password was accepted")
	}

	t.Setenv("RELAY_ADMIN_PASSWORD", "long-random-password")
	t.Setenv("RELAY_CREDENTIAL_TTL", "2h")
	t.Setenv("RELAY_SESSION_TTL", "10m")
	t.Setenv("RELAY_ADMIN_SESSION_TTL", "6h")
	t.Setenv("RELAY_MAX_CONNECTIONS", "512")
	t.Setenv("RELAY_MAX_ENROLLED_DEVICES", "1024")
	t.Setenv("RELAY_MAX_TRANSFER_SESSIONS", "2048")
	t.Setenv("RELAY_MAX_PENDING_FRAMES_PER_DEVICE", "48")
	t.Setenv("RELAY_MAX_PENDING_BYTES_PER_DEVICE", "1048576")
	t.Setenv("RELAY_MAX_FRAMES_PER_SECOND_PER_DEVICE", "128")
	t.Setenv("RELAY_MAX_BYTES_PER_SECOND_PER_DEVICE", "8388608")
	t.Setenv("RELAY_MAX_ADMIN_SESSIONS", "8")
	t.Setenv("RELAY_ADMIN_LOGIN_MAX_ATTEMPTS", "3")
	t.Setenv("RELAY_ADMIN_LOGIN_WINDOW", "2m")
	t.Setenv("RELAY_ADMIN_LOGIN_BLOCK", "7m")
	t.Setenv("RELAY_MAX_ADMIN_LOGIN_ENTRIES", "256")
	t.Setenv("RELAY_HTTP_READ_TIMEOUT", "20s")
	t.Setenv("RELAY_HTTP_WRITE_TIMEOUT", "30s")
	t.Setenv("RELAY_HTTP_IDLE_TIMEOUT", "90s")
	t.Setenv("RELAY_HTTP_MAX_HEADER_BYTES", "32768")
	t.Setenv("RELAY_MAX_REVOKED_DEVICES", "512")
	t.Setenv("RELAY_TRUSTED_PROXY_CIDRS", "10.0.0.0/8, 192.168.1.10")
	config, err := ConfigFromEnvironment()
	if err != nil {
		t.Fatalf("valid relay configuration failed: %v", err)
	}
	if config.Address != ":9090" {
		t.Fatalf("unexpected default address %q", config.Address)
	}
	if config.CredentialTTL != 2*time.Hour || config.SessionTTL != 10*time.Minute || config.AdminSessionTTL != 6*time.Hour {
		t.Fatalf("duration environment values were not loaded: credential=%s session=%s admin=%s", config.CredentialTTL, config.SessionTTL, config.AdminSessionTTL)
	}
	if config.MaxConnections != 512 {
		t.Fatalf("max connection environment value was not loaded: %d", config.MaxConnections)
	}
	if config.MaxEnrolledDevices != 1024 || config.MaxTransferSessions != 2048 ||
		config.MaxPendingFramesPerDevice != 48 || config.MaxPendingBytesPerDevice != 1048576 ||
		config.MaxFramesPerSecondPerDevice != 128 || config.MaxBytesPerSecondPerDevice != 8388608 ||
		config.MaxAdminSessions != 8 || config.AdminLoginMaxAttempts != 3 ||
		config.AdminLoginWindow != 2*time.Minute || config.AdminLoginBlockDuration != 7*time.Minute ||
		config.MaxAdminLoginEntries != 256 || config.HTTPReadTimeout != 20*time.Second ||
		config.HTTPWriteTimeout != 30*time.Second || config.HTTPIdleTimeout != 90*time.Second ||
		config.HTTPMaxHeaderBytes != 32768 {
		t.Fatalf("resource and HTTP environment values were not loaded: %+v", config)
	}
	if config.MaxRevokedDevices != 512 {
		t.Fatalf("max revoked device environment value was not loaded: %d", config.MaxRevokedDevices)
	}
	if len(config.TrustedProxyCIDRs) != 2 ||
		config.TrustedProxyCIDRs[0].String() != "10.0.0.0/8" ||
		config.TrustedProxyCIDRs[1].String() != "192.168.1.10/32" {
		t.Fatalf("trusted proxy CIDR environment value was not loaded: %+v", config.TrustedProxyCIDRs)
	}
}

func TestConfigDefaultsAreFiniteAndProxyBoundaryIsClosed(t *testing.T) {
	cfg := withConfigDefaults(Config{})
	if cfg.MaxRevokedDevices != defaultMaxRevokedDevices {
		t.Fatalf("default max revoked devices not applied: %d", cfg.MaxRevokedDevices)
	}
	if cfg.HTTPWriteTimeout != defaultHTTPWriteTimeout {
		t.Fatalf("default HTTP write timeout not applied: %s", cfg.HTTPWriteTimeout)
	}
	if len(cfg.TrustedProxyCIDRs) != 0 {
		t.Fatalf("trusted proxy CIDRs should default to an empty boundary: %+v", cfg.TrustedProxyCIDRs)
	}
}

func TestTrustedProxyCIDRListParsing(t *testing.T) {
	t.Setenv("RELAY_ENROLLMENT_TOKEN", "0123456789abcdef")
	t.Setenv(
		"RELAY_CREDENTIAL_KEY",
		"MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE",
	)
	t.Setenv("RELAY_ADMIN_USER", "admin")
	t.Setenv("RELAY_ADMIN_PASSWORD", "long-random-password")
	t.Setenv("RELAY_TRUSTED_PROXY_CIDRS", " 10.1.0.0/16 , 172.30.0.10, bogus,  ")
	config, err := ConfigFromEnvironment()
	if err != nil {
		t.Fatalf("valid relay configuration failed: %v", err)
	}
	if len(config.TrustedProxyCIDRs) != 2 ||
		config.TrustedProxyCIDRs[0].String() != "10.1.0.0/16" ||
		config.TrustedProxyCIDRs[1].String() != "172.30.0.10/32" {
		t.Fatalf("unexpected trusted proxy CIDR parse: %+v", config.TrustedProxyCIDRs)
	}
}
