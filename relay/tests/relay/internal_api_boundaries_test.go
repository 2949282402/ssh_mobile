package relay_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/ssh-mobile/relay/internal/relay"
)

func TestInternalAPIRejectsInvalidRevocationAndAttestationMethods(t *testing.T) {
	server, mux := newRelayTestServer(t)
	if outcome, err := server.RevokeDevice(context.Background(), ""); outcome != relay.RevokeStatusNotFound || err == nil {
		t.Fatalf("empty direct revocation = outcome=%v err=%v, want not found with validation error", outcome, err)
	}
	if outcome, err := server.RevokeDevice(context.Background(), strings.Repeat("x", 129)); outcome != relay.RevokeStatusNotFound || err == nil {
		t.Fatalf("overlong direct revocation = outcome=%v err=%v, want not found with validation error", outcome, err)
	}

	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	enrollRelayDevice(t, mux, "method-boundary-device", publicKey)
	request := httptest.NewRequest(http.MethodGet, relay.PathInternalTelemetryAttest, nil)
	request.Header.Set("Authorization", "Bearer "+testInternalToken)
	response := httptest.NewRecorder()
	mux.ServeHTTP(response, request)
	if response.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET telemetry attestation status = %d, want 405: %s", response.Code, response.Body.String())
	}
}

func TestInternalAPIReportsClosedPersistentSnapshotDependencies(t *testing.T) {
	dsn := os.Getenv("RELAY_TEST_MYSQL_DSN")
	redisURL := os.Getenv("RELAY_TEST_REDIS_URL")
	if dsn == "" || redisURL == "" {
		t.Skip("RELAY_TEST_MYSQL_DSN and RELAY_TEST_REDIS_URL are required for persistent snapshot failure coverage")
	}
	server, err := relay.OpenServer(relay.Config{
		StorageMode:     "mysql",
		DatabaseURL:     dsn,
		RedisURL:        redisURL,
		CredentialKey:   []byte(testCredentialKey),
		EnrollmentToken: testEnrollmentToken,
		InternalToken:   testInternalToken,
		CredentialTTL:   time.Hour,
	})
	if err != nil {
		t.Fatalf("open persistent relay for closed snapshot: %v", err)
	}
	server.Close()
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	for _, path := range []string{relay.PathInternalStatusV2, relay.PathInternalDevicesV2} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.Header.Set("Authorization", "Bearer "+testInternalToken)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code != http.StatusInternalServerError {
			t.Fatalf("closed persistent %s status = %d, want 500: %s", path, rec.Code, rec.Body.String())
		}
	}
}
