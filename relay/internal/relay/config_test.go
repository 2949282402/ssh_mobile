package relay

import "testing"

func TestConfigRequiresExplicitSecretsAndAdministrator(t *testing.T) {
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
	config, err := ConfigFromEnvironment()
	if err != nil {
		t.Fatalf("valid relay configuration failed: %v", err)
	}
	if config.Address != ":8080" {
		t.Fatalf("unexpected default address %q", config.Address)
	}
}
