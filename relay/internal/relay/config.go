package relay

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"log"
	"os"
	"strconv"
	"time"
)

const (
	maxControlFrameBytes = 64 * 1024
	maxBinaryFrameBytes  = 1024*1024 + 25
)

type Config struct {
	Address         string
	EnrollmentToken string
	CredentialKey   []byte
	CredentialTTL   time.Duration
	SessionTTL      time.Duration
	MaxConnections  int
}

func ConfigFromEnvironment() (Config, error) {
	enrollment := os.Getenv("RELAY_ENROLLMENT_TOKEN")
	if enrollment == "" {
		enrollment = hex.EncodeToString(randomBytes(16))
		log.Printf("[Relay] RELAY_ENROLLMENT_TOKEN not set; auto-generated: %s", enrollment)
	}

	var decoded []byte
	key := os.Getenv("RELAY_CREDENTIAL_KEY")
	if key == "" {
		decoded = randomBytes(32)
		log.Printf("[Relay] RELAY_CREDENTIAL_KEY not set; auto-generated random 32-byte secret key")
	} else {
		var err error
		decoded, err = base64.RawURLEncoding.DecodeString(key)
		if err != nil || len(decoded) < 32 {
			return Config{}, errors.New("RELAY_CREDENTIAL_KEY must be base64url encoded and at least 32 bytes")
		}
	}

	return Config{
		Address:         os.Getenv("RELAY_ADDR"),
		EnrollmentToken: enrollment,
		CredentialKey:   decoded,
		CredentialTTL:   durationEnv("RELAY_CREDENTIAL_TTL", 24*time.Hour),
		SessionTTL:      durationEnv("RELAY_SESSION_TTL", 15*time.Minute),
		MaxConnections:  intEnv("RELAY_MAX_CONNECTIONS", 2048),
	}, nil
}

func durationEnv(name string, fallback time.Duration) time.Duration {
	if value, err := time.ParseDuration(os.Getenv(name)); err == nil && value > 0 {
		return value
	}
	return fallback
}
func intEnv(name string, fallback int) int {
	if value, err := strconv.Atoi(os.Getenv(name)); err == nil && value > 0 {
		return value
	}
	return fallback
}

func randomBytes(size int) []byte {
	b := make([]byte, size)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}
