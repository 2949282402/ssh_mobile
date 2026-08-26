package relay

import (
	"os"
	"strings"
	"testing"
	"time"
)

func setValidConfigEnvironment(t *testing.T) {
	t.Helper()
	t.Setenv("RELAY_ENROLLMENT_TOKEN", "0123456789abcdef")
	t.Setenv(
		"RELAY_CREDENTIAL_KEY",
		"MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE",
	)
	t.Setenv("RELAY_INTERNAL_TOKEN", "0123456789abcdef0123456789abcdef")
	t.Setenv("RELAY_PUBLIC_URL", "wss://relay.example.test")
	t.Setenv("RELAY_ADMIN_USER", "admin")
	t.Setenv("RELAY_ADMIN_PASSWORD", "long-random-password")
}

func TestConfigRequiresExplicitSecretsAndAdministrator(t *testing.T) {
	t.Setenv("RELAY_ADDR", ":9090")
	t.Setenv("RELAY_ENROLLMENT_TOKEN", "0123456789abcdef")
	t.Setenv(
		"RELAY_CREDENTIAL_KEY",
		"MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE",
	)
	t.Setenv("RELAY_PUBLIC_URL", "wss://relay.example.test")
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
	t.Setenv("RELAY_INTERNAL_TOKEN", "")
	if _, err := ConfigFromEnvironment(); err == nil {
		t.Fatal("missing internal token was accepted")
	}
	t.Setenv("RELAY_INTERNAL_TOKEN", "short-token")
	if _, err := ConfigFromEnvironment(); err == nil {
		t.Fatal("short internal token was accepted")
	}
	t.Setenv("RELAY_INTERNAL_TOKEN", "0123456789abcdef0123456789abcdef")
	t.Setenv("RELAY_CREDENTIAL_TTL", "2h")
	t.Setenv("RELAY_ADMIN_SESSION_TTL", "6h")
	t.Setenv("RELAY_MAX_CONNECTIONS", "512")
	t.Setenv("RELAY_MAX_TRANSFER_SESSIONS", "128")
	t.Setenv("RELAY_MAX_ENROLLED_DEVICES", "1024")
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
	if config.CredentialTTL != 2*time.Hour || config.AdminSessionTTL != 6*time.Hour {
		t.Fatalf("duration environment values were not loaded: credential=%s admin=%s", config.CredentialTTL, config.AdminSessionTTL)
	}
	if config.MaxConnections != 512 || config.MaxTransferSessions != 128 {
		t.Fatalf("connection/transfer environment values were not loaded: %+v", config)
	}
	if config.MaxEnrolledDevices != 1024 ||
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
	if cfg.MaxTransferSessions != defaultMaxTransferSessions {
		t.Fatalf("default max transfer sessions not applied: %d", cfg.MaxTransferSessions)
	}
	if cfg.HTTPWriteTimeout != defaultHTTPWriteTimeout {
		t.Fatalf("default HTTP write timeout not applied: %s", cfg.HTTPWriteTimeout)
	}
	if len(cfg.TrustedProxyCIDRs) != 0 {
		t.Fatalf("trusted proxy CIDRs should default to an empty boundary: %+v", cfg.TrustedProxyCIDRs)
	}
}

// TestRelayDataEndpointOrigin 固定 relay_data_endpoint 公共源的构造：显式 PublicURL
// 优先（可带或不带 scheme、容忍尾部斜杠）；未配置时从监听地址派生，通配主机退化到
// localhost。该源永不读取客户端 Host 头。
func TestRelayDataEndpointOrigin(t *testing.T) {
	cases := []struct {
		cfg  Config
		want string
	}{
		{Config{PublicURL: "wss://relay.example.com"}, "wss://relay.example.com"},
		{Config{PublicURL: "relay.example.com:9443"}, "wss://relay.example.com:9443"},
		{Config{PublicURL: "https://relay.example.com/"}, "wss://relay.example.com"},
		{Config{PublicURL: "http://127.0.0.1:18080/"}, "ws://127.0.0.1:18080"},
		{Config{Address: ":8080"}, "wss://localhost:8080"},
		{Config{Address: "0.0.0.0:8080"}, "wss://localhost:8080"},
		{Config{Address: "127.0.0.1:9090"}, "wss://127.0.0.1:9090"},
	}
	for _, c := range cases {
		if got := relayDataEndpointOrigin(c.cfg); got != c.want {
			t.Errorf("relayDataEndpointOrigin(%+v) = %q, want %q", c.cfg, got, c.want)
		}
	}
}

func TestConfigStorageModeDefaultsToMemoryAndRejectsUnknown(t *testing.T) {
	setValidConfigEnvironment(t)

	t.Setenv("RELAY_STORAGE_MODE", "")
	config, err := ConfigFromEnvironment()
	if err != nil {
		t.Fatalf("valid relay configuration failed: %v", err)
	}
	if config.StorageMode != "memory" {
		t.Fatalf("storage mode should default to memory, got %q", config.StorageMode)
	}

	t.Setenv("RELAY_STORAGE_MODE", "postgres")
	if _, err := ConfigFromEnvironment(); err == nil {
		t.Fatal("unsupported storage mode was accepted")
	}

	t.Setenv("RELAY_STORAGE_MODE", "mysql")
	t.Setenv("RELAY_DATABASE_URL", "")
	if _, err := ConfigFromEnvironment(); err == nil {
		t.Fatal("mysql storage mode without a database URL was accepted")
	}
	t.Setenv("RELAY_DATABASE_URL", "user:pass@tcp(localhost:3306)/relay?parseTime=true&loc=UTC")
	t.Setenv("RELAY_REDIS_URL", "")
	if _, err := ConfigFromEnvironment(); err == nil {
		t.Fatal("mysql storage mode without a redis URL was accepted")
	}
	t.Setenv("RELAY_REDIS_URL", "redis://localhost:6379/0")
	t.Setenv("RELAY_REDIS_PASSWORD", "")
	if _, err := ConfigFromEnvironment(); err == nil {
		t.Fatal("mysql storage mode without a Redis password was accepted")
	}
	t.Setenv("RELAY_REDIS_PASSWORD", "long-random-redis-password")
	t.Setenv("RELAY_INSTANCE_ID", "relay-test")
	t.Setenv("RELAY_PRESENCE_TTL", "30s")
	mysqlConfig, err := ConfigFromEnvironment()
	if err != nil {
		t.Fatalf("mysql storage configuration failed: %v", err)
	}
	if mysqlConfig.StorageMode != "mysql" || mysqlConfig.DatabaseURL == "" {
		t.Fatalf("mysql storage configuration was not loaded: %+v", mysqlConfig)
	}
	if mysqlConfig.RedisURL != "redis://localhost:6379/0" || mysqlConfig.InstanceID != "relay-test" {
		t.Fatalf("redis/instance configuration was not loaded: %+v", mysqlConfig)
	}
	if mysqlConfig.PresenceTTL != 30*time.Second {
		t.Fatalf("presence TTL was not loaded: %s", mysqlConfig.PresenceTTL)
	}
}

func TestTrustedProxyCIDRListParsing(t *testing.T) {
	setValidConfigEnvironment(t)
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

func TestConfigRejectsPublishedExampleCredentials(t *testing.T) {
	for _, test := range []struct {
		name  string
		value string
	}{
		{"RELAY_ENROLLMENT_TOKEN", publishedExampleEnrollmentToken},
		{"RELAY_CREDENTIAL_KEY", publishedExampleCredentialKey},
		{"RELAY_ADMIN_USER", publishedExampleAdminUser},
		{"RELAY_ADMIN_PASSWORD", publishedExampleAdminPassword},
	} {
		t.Run(test.name, func(t *testing.T) {
			setValidConfigEnvironment(t)
			t.Setenv(test.name, test.value)
			if _, err := ConfigFromEnvironment(); err == nil {
				t.Fatalf("published example value for %s was accepted", test.name)
			}
		})
	}
}

func TestEnvironmentExampleLeavesRuntimeSecretsUnset(t *testing.T) {
	data, err := os.ReadFile("../../.env.example")
	if err != nil {
		t.Fatal(err)
	}
	content := string(data)
	for _, name := range []string{
		"RELAY_ENROLLMENT_TOKEN",
		"RELAY_CREDENTIAL_KEY",
		"RELAY_ADMIN_USER",
		"RELAY_ADMIN_PASSWORD",
		"RELAY_REDIS_PASSWORD",
	} {
		prefix := name + "="
		found := false
		for _, line := range strings.Split(content, "\n") {
			if strings.HasPrefix(line, prefix) {
				found = true
				if line != prefix {
					t.Fatalf("%s must be empty in .env.example", name)
				}
			}
		}
		if !found {
			t.Fatalf("%s is missing from .env.example", name)
		}
	}
}

func TestConfigRejectsExplicitInvalidPositiveValues(t *testing.T) {
	for _, test := range []struct {
		name  string
		value string
	}{
		{"RELAY_CREDENTIAL_TTL", "not-a-duration"},
		{"RELAY_HTTP_READ_TIMEOUT", "0s"},
		{"RELAY_ADMIN_LOGIN_WINDOW", "-1s"},
		{"RELAY_MAX_CONNECTIONS", "not-an-int"},
		{"RELAY_MAX_TRANSFER_SESSIONS", "0"},
		{"RELAY_MAX_PENDING_BYTES_PER_DEVICE", "-1"},
	} {
		t.Run(test.name+"="+test.value, func(t *testing.T) {
			setValidConfigEnvironment(t)
			t.Setenv(test.name, test.value)
			if _, err := ConfigFromEnvironment(); err == nil {
				t.Fatalf("explicit invalid value %s=%q was accepted", test.name, test.value)
			}
		})
	}
}

func TestConfigValidatesPublishedRelayOrigin(t *testing.T) {
	for _, test := range []struct {
		value string
		valid bool
	}{
		{"wss://relay.example.test", true},
		{"relay.example.test:9443", true},
		{"http://127.0.0.1:18080", true},
		{"", false},
		{"wss://localhost:8080", false},
		{"http://relay.example.test", false},
		{"ftp://relay.example.test", false},
		{"wss://user@relay.example.test", false},
		{"wss://relay.example.test/path", false},
		{"wss://relay.example.test?token=secret", false},
	} {
		t.Run(test.value, func(t *testing.T) {
			setValidConfigEnvironment(t)
			t.Setenv("RELAY_PUBLIC_URL", test.value)
			_, err := ConfigFromEnvironment()
			if (err == nil) != test.valid {
				t.Fatalf("RELAY_PUBLIC_URL=%q valid=%v, error=%v", test.value, test.valid, err)
			}
		})
	}
}
