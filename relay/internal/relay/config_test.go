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
	t.Setenv("RELAY_MAX_CONNECTIONS", "512")
	config, err := ConfigFromEnvironment()
	if err != nil {
		t.Fatalf("valid relay configuration failed: %v", err)
	}
	if config.Address != ":9090" {
		t.Fatalf("unexpected default address %q", config.Address)
	}
	if config.CredentialTTL != 2*time.Hour || config.SessionTTL != 10*time.Minute {
		t.Fatalf("duration environment values were not loaded: credential=%s session=%s", config.CredentialTTL, config.SessionTTL)
	}
	if config.MaxConnections != 512 {
		t.Fatalf("max connection environment value was not loaded: %d", config.MaxConnections)
	}
}
