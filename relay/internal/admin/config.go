// Admin backend configuration and environment parsing.

package admin

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"net/netip"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/ssh-mobile/relay/internal/telemetry"
)

const (
	defaultAddress            = ":8081"
	defaultSessionTTL         = 24 * time.Hour
	defaultMaxSessions        = 32
	defaultLoginMaxAttempts   = 5
	defaultLoginWindow        = time.Minute
	defaultLoginBlockDuration = 5 * time.Minute
	defaultMaxLoginEntries    = 4096
	defaultHTTPReadTimeout    = 15 * time.Second
	defaultHTTPWriteTimeout   = 15 * time.Second
	defaultHTTPIdleTimeout    = 60 * time.Second
	defaultHTTPMaxHeaderBytes = 16 * 1024
	defaultRelayURL           = "http://relay:8080"

	publishedExampleAdminUser     = "replace-with-an-admin-username"
	publishedExampleAdminPassword = "replace-with-a-random-password-of-at-least-12-characters"
	publishedExampleAdminAuthKey  = "replace-with-a-32-byte-base64url-random-auth-key"
	publishedExampleInternalToken = "replace-with-a-32-byte-random-internal-token"
)

// Config holds the configuration for the standalone Admin backend service.
type Config struct {
	Address             string
	AdminUser           string
	AdminPassword       string
	AuthKey             []byte
	SessionTTL          time.Duration
	MaxSessions         int
	LoginMaxAttempts    int
	LoginWindow         time.Duration
	LoginBlockDuration  time.Duration
	MaxLoginEntries     int
	TrustedProxyCIDRs   []netip.Prefix
	HTTPReadTimeout     time.Duration
	HTTPWriteTimeout    time.Duration
	HTTPIdleTimeout     time.Duration
	HTTPMaxHeaderBytes  int
	RelayURL            string
	RelayInternalToken  string
	TelemetryMySQLDSN   string
	TelemetryRedisURL   string
	TelemetryAuthSecret string
	TelemetryIngest     telemetry.IngestConfig
}

// ConfigFromEnvironment loads and validates Admin backend configuration from environment variables.
func ConfigFromEnvironment() (Config, error) {
	address := os.Getenv("ADMIN_ADDR")
	if address == "" {
		address = defaultAddress
	}

	adminUser := os.Getenv("ADMIN_USER")
	if adminUser == "" || adminUser == publishedExampleAdminUser {
		return Config{}, errors.New("ADMIN_USER must be set")
	}
	adminPassword := os.Getenv("ADMIN_PASSWORD")
	if len(adminPassword) < 12 || adminPassword == publishedExampleAdminPassword {
		return Config{}, errors.New("ADMIN_PASSWORD must be set and contain at least 12 characters")
	}

	rawAuthKey := os.Getenv("ADMIN_AUTH_KEY")
	var authKey []byte
	if rawAuthKey == "" || rawAuthKey == publishedExampleAdminAuthKey {
		return Config{}, errors.New("ADMIN_AUTH_KEY must be set")
	}
	var err error
	authKey, err = base64.RawURLEncoding.DecodeString(rawAuthKey)
	if err != nil || len(authKey) < 32 {
		return Config{}, errors.New("ADMIN_AUTH_KEY must be base64url encoded and contain at least 32 bytes")
	}

	relayURLStr := os.Getenv("ADMIN_RELAY_URL")
	if relayURLStr == "" {
		relayURLStr = defaultRelayURL
	}
	parsedURL, err := url.Parse(relayURLStr)
	if err != nil || (parsedURL.Scheme != "http" && parsedURL.Scheme != "https") || parsedURL.Host == "" {
		return Config{}, fmt.Errorf("ADMIN_RELAY_URL is invalid: %q", relayURLStr)
	}

	relayInternalToken := os.Getenv("ADMIN_RELAY_INTERNAL_TOKEN")
	if len(relayInternalToken) < 32 || relayInternalToken == publishedExampleInternalToken {
		return Config{}, errors.New("ADMIN_RELAY_INTERNAL_TOKEN must be set and contain at least 32 characters")
	}

	var parseErr error
	readDuration := func(name string, fallback time.Duration) time.Duration {
		if parseErr != nil {
			return fallback
		}
		value, err := durationEnv(name, fallback)
		if err != nil {
			parseErr = err
		}
		return value
	}
	readInt := func(name string, fallback int) int {
		if parseErr != nil {
			return fallback
		}
		value, err := intEnv(name, fallback)
		if err != nil {
			parseErr = err
		}
		return value
	}

	config := Config{
		Address:             address,
		AdminUser:           adminUser,
		AdminPassword:       adminPassword,
		AuthKey:             authKey,
		SessionTTL:          readDuration("ADMIN_SESSION_TTL", defaultSessionTTL),
		MaxSessions:         readInt("ADMIN_MAX_SESSIONS", defaultMaxSessions),
		LoginMaxAttempts:    readInt("ADMIN_LOGIN_MAX_ATTEMPTS", defaultLoginMaxAttempts),
		LoginWindow:         readDuration("ADMIN_LOGIN_WINDOW", defaultLoginWindow),
		LoginBlockDuration:  readDuration("ADMIN_LOGIN_BLOCK", defaultLoginBlockDuration),
		MaxLoginEntries:     readInt("ADMIN_MAX_LOGIN_ENTRIES", defaultMaxLoginEntries),
		HTTPReadTimeout:     readDuration("ADMIN_HTTP_READ_TIMEOUT", defaultHTTPReadTimeout),
		HTTPWriteTimeout:    readDuration("ADMIN_HTTP_WRITE_TIMEOUT", defaultHTTPWriteTimeout),
		HTTPIdleTimeout:     readDuration("ADMIN_HTTP_IDLE_TIMEOUT", defaultHTTPIdleTimeout),
		HTTPMaxHeaderBytes:  readInt("ADMIN_HTTP_MAX_HEADER_BYTES", defaultHTTPMaxHeaderBytes),
		TrustedProxyCIDRs:   cidrListEnv("ADMIN_TRUSTED_PROXY_CIDRS"),
		RelayURL:            relayURLStr,
		RelayInternalToken:  relayInternalToken,
		TelemetryMySQLDSN:   strings.TrimSpace(os.Getenv("TELEMETRY_MYSQL_DSN")),
		TelemetryRedisURL:   strings.TrimSpace(os.Getenv("TELEMETRY_REDIS_URL")),
		TelemetryAuthSecret: strings.TrimSpace(os.Getenv("TELEMETRY_AUTH_SECRET")),
	}
	config.TelemetryIngest, err = telemetry.IngestConfigFromEnvironment()
	if err != nil {
		return Config{}, err
	}

	if parseErr != nil {
		return Config{}, parseErr
	}
	return config, nil
}

func cidrListEnv(name string) []netip.Prefix {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return nil
	}
	var prefixes []netip.Prefix
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if prefix, err := netip.ParsePrefix(part); err == nil {
			prefixes = append(prefixes, prefix)
			continue
		}
		if addr, err := netip.ParseAddr(part); err == nil {
			prefixes = append(prefixes, netip.PrefixFrom(addr, addr.BitLen()))
		}
	}
	return prefixes
}

func withConfigDefaults(config Config) Config {
	if config.Address == "" {
		config.Address = defaultAddress
	}
	if config.SessionTTL <= 0 {
		config.SessionTTL = defaultSessionTTL
	}
	if config.MaxSessions <= 0 {
		config.MaxSessions = defaultMaxSessions
	}
	if config.LoginMaxAttempts <= 0 {
		config.LoginMaxAttempts = defaultLoginMaxAttempts
	}
	if config.LoginWindow <= 0 {
		config.LoginWindow = defaultLoginWindow
	}
	if config.LoginBlockDuration <= 0 {
		config.LoginBlockDuration = defaultLoginBlockDuration
	}
	if config.MaxLoginEntries <= 0 {
		config.MaxLoginEntries = defaultMaxLoginEntries
	}
	if config.HTTPReadTimeout <= 0 {
		config.HTTPReadTimeout = defaultHTTPReadTimeout
	}
	if config.HTTPWriteTimeout <= 0 {
		config.HTTPWriteTimeout = defaultHTTPWriteTimeout
	}
	if config.HTTPIdleTimeout <= 0 {
		config.HTTPIdleTimeout = defaultHTTPIdleTimeout
	}
	if config.HTTPMaxHeaderBytes <= 0 {
		config.HTTPMaxHeaderBytes = defaultHTTPMaxHeaderBytes
	}
	if config.RelayURL == "" {
		config.RelayURL = defaultRelayURL
	}
	return config
}

func durationEnv(name string, fallback time.Duration) (time.Duration, error) {
	raw := os.Getenv(name)
	if raw == "" {
		return fallback, nil
	}
	val, err := time.ParseDuration(raw)
	if err != nil {
		return 0, fmt.Errorf("%s must be a valid duration: %w", name, err)
	}
	return val, nil
}

func intEnv(name string, fallback int) (int, error) {
	raw := os.Getenv(name)
	if raw == "" {
		return fallback, nil
	}
	val, err := strconv.Atoi(raw)
	if err != nil || val <= 0 {
		return 0, fmt.Errorf("%s must be a positive integer", name)
	}
	return val, nil
}

func randomBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}
