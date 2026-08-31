package admin_test

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/admin"
	telemetrypkg "github.com/ssh-mobile/relay/internal/telemetry"
)

const revokeTestAuthSecret = "telemetry-auth-secret-for-tests"

func newTelemetryRevokeServer(
	t *testing.T,
	client *managementClientStub,
	service *telemetrypkg.Service,
) (*http.ServeMux, func()) {
	t.Helper()
	server := NewServerWithClientAndTelemetry(
		Config{
			Address:       ":0",
			AdminUser:     "admin",
			AdminPassword: "password-long-enough",
			AuthKey:       []byte("01234567890123456789012345678901"),
		},
		client,
		service,
	)
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	return mux, func() { _ = server.Close() }
}

func TestAdminRevokeRevokesTelemetryBeforeRelay(t *testing.T) {
	const (
		deviceID = "revoke-telemetry-device"
		secret   = "old-telemetry-secret"
	)
	catalog := telemetrypkg.DefaultCatalog()
	store := telemetrypkg.NewMemoryStore(catalog)
	secretHash := sha256.Sum256([]byte(secret))
	secretHashHex := hex.EncodeToString(secretHash[:])
	if err := store.CreateDeviceCredential(context.Background(), deviceID, secretHashHex); err != nil {
		t.Fatalf("seed telemetry credential: %v", err)
	}
	service := telemetrypkg.NewServiceWithSecret(
		store,
		catalog,
		&telemetrypkg.NoopRedisCache{},
		revokeTestAuthSecret,
	)

	oldToken, _ := service.GenerateDeviceToken(deviceID, time.Hour)
	expEpoch := time.Now().UTC().Add(time.Minute).Unix()
	proofMAC := hmac.New(sha256.New, []byte(secretHashHex))
	_, _ = proofMAC.Write([]byte("telemetry:auth:" + deviceID + ":" + strconv.FormatInt(expEpoch, 10)))
	oldProof := hex.EncodeToString(proofMAC.Sum(nil))
	if _, _, err := service.AuthenticateDevice(context.Background(), deviceID, oldProof, expEpoch); err != nil {
		t.Fatalf("old telemetry secret should authenticate before revoke: %v", err)
	}
	if !service.VerifyDeviceTokenAt(context.Background(), deviceID, oldToken) {
		t.Fatal("old bearer token should verify before revoke")
	}
	relayObservedTelemetryRevoked := false
	client := &managementClientStub{
		revokeHook: func() {
			relayObservedTelemetryRevoked = !service.VerifyDeviceTokenAt(context.Background(), deviceID, oldToken)
		},
	}
	mux, closeServer := newTelemetryRevokeServer(t, client, service)
	defer closeServer()
	cookie := adminLoginCookie(t, mux)

	revoke := serveAdminRequest(mux, http.MethodPost, PathRevokeDevice+deviceID+"/revoke", cookie)
	if revoke.Code != http.StatusNoContent {
		t.Fatalf("revoke status = %d, want 204: %s", revoke.Code, revoke.Body.String())
	}
	if client.revokeCalls != 1 {
		t.Fatalf("Relay revoke calls = %d, want 1", client.revokeCalls)
	}
	if !relayObservedTelemetryRevoked {
		t.Fatal("Relay revoke was called before the telemetry credential was revoked")
	}

	if _, _, err := service.AuthenticateDevice(context.Background(), deviceID, oldProof, expEpoch); !errors.Is(err, telemetrypkg.ErrDeviceNotRegistered) {
		t.Fatalf("old telemetry secret error = %v, want ErrDeviceNotRegistered", err)
	}
	if service.VerifyDeviceTokenAt(context.Background(), deviceID, oldToken) {
		t.Fatal("old bearer token remained valid after revoke")
	}

	// Exercise the public ingest boundary with the token issued before revoke.
	telemetryMux := http.NewServeMux()
	telemetrypkg.NewHandler(service).RegisterPublicRoutes(telemetryMux)
	envelope := telemetrypkg.TelemetryEnvelope{
		EventID:      "revoke-after-token",
		RecordType:   telemetrypkg.RecordTypeAnalytics,
		EventName:    "ssh.session.started",
		EventVersion: 1,
		DeviceID:     deviceID,
		SessionID:    "session",
		TraceID:      "trace",
		OccurredAt:   time.Now().UTC(),
		Feature:      "ssh",
		Severity:     telemetrypkg.SeverityInfo,
		AppVersion:   "1.0.0",
		BuildNumber:  "1",
		Platform:     "linux",
		Properties:   map[string]any{"session_type": "interactive"},
	}
	body, err := json.Marshal(telemetrypkg.IngestBatchRequest{Records: []telemetrypkg.TelemetryEnvelope{envelope}})
	if err != nil {
		t.Fatal(err)
	}
	ingestRequest := httptest.NewRequest(http.MethodPost, telemetrypkg.PathPublicIngest, bytes.NewReader(body))
	ingestRequest.Header.Set("Content-Type", "application/json")
	ingestRequest.Header.Set("Authorization", "Bearer "+oldToken)
	ingestRequest.Header.Set("X-Device-Id", deviceID)
	ingestResponse := httptest.NewRecorder()
	telemetryMux.ServeHTTP(ingestResponse, ingestRequest)
	if ingestResponse.Code != http.StatusUnauthorized {
		t.Fatalf("old bearer ingest status = %d, want 401", ingestResponse.Code)
	}
}

func TestAdminRevokeFailsClosedWhenConfiguredTelemetryStoreUnavailable(t *testing.T) {
	// Passing a non-nil service with no Store models a configured deployment
	// whose Analytics MySQL store is currently unavailable.
	service := telemetrypkg.NewServiceWithSecret(
		nil,
		telemetrypkg.DefaultCatalog(),
		&telemetrypkg.NoopRedisCache{},
		revokeTestAuthSecret,
	)
	client := &managementClientStub{}
	mux, closeServer := newTelemetryRevokeServer(t, client, service)
	defer closeServer()
	cookie := adminLoginCookie(t, mux)

	revoke := serveAdminRequest(mux, http.MethodPost, PathRevokeDevice+"configured-unavailable/revoke", cookie)
	if revoke.Code != http.StatusServiceUnavailable {
		t.Fatalf("revoke status = %d, want 503: %s", revoke.Code, revoke.Body.String())
	}
	if client.revokeCalls != 0 {
		t.Fatalf("Relay revoke calls = %d, want 0 when telemetry store is unavailable", client.revokeCalls)
	}
}

func TestAdminRevokeFailsClosedWhenConfiguredTelemetryDSNCannotOpen(t *testing.T) {
	client := &managementClientStub{}
	server := NewServerWithClient(Config{
		Address:           ":0",
		AdminUser:         "admin",
		AdminPassword:     "password-long-enough",
		AuthKey:           []byte("01234567890123456789012345678901"),
		TelemetryMySQLDSN: "not-a-mysql-dsn",
	}, client)
	defer server.Close()
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	cookie := adminLoginCookie(t, mux)

	revoke := serveAdminRequest(mux, http.MethodPost, PathRevokeDevice+"configured-dsn-unavailable/revoke", cookie)
	if revoke.Code != http.StatusServiceUnavailable {
		t.Fatalf("revoke status = %d, want 503: %s", revoke.Code, revoke.Body.String())
	}
	if client.revokeCalls != 0 {
		t.Fatalf("Relay revoke calls = %d, want 0 when configured telemetry DSN cannot open", client.revokeCalls)
	}
}

func TestAdminRevokeFailsClosedOnTelemetryCredentialStoreError(t *testing.T) {
	baseStore := telemetrypkg.NewMemoryStore(telemetrypkg.DefaultCatalog())
	if err := baseStore.CreateDeviceCredential(context.Background(), "store-error-device", "credential-hash"); err != nil {
		t.Fatalf("seed telemetry credential: %v", err)
	}
	service := telemetrypkg.NewServiceWithSecret(
		&revokeFailureStore{MemoryStore: baseStore, err: errors.New("temporary telemetry store failure")},
		telemetrypkg.DefaultCatalog(),
		&telemetrypkg.NoopRedisCache{},
		revokeTestAuthSecret,
	)
	client := &managementClientStub{}
	mux, closeServer := newTelemetryRevokeServer(t, client, service)
	defer closeServer()
	cookie := adminLoginCookie(t, mux)

	revoke := serveAdminRequest(mux, http.MethodPost, PathRevokeDevice+"store-error-device/revoke", cookie)
	if revoke.Code != http.StatusServiceUnavailable {
		t.Fatalf("revoke status = %d, want 503: %s", revoke.Code, revoke.Body.String())
	}
	if client.revokeCalls != 0 {
		t.Fatalf("Relay revoke calls = %d, want 0 after telemetry store error", client.revokeCalls)
	}
}

func TestAdminRevokeContinuesWithoutTelemetryCredential(t *testing.T) {
	service := telemetrypkg.NewServiceWithSecret(
		telemetrypkg.NewMemoryStore(telemetrypkg.DefaultCatalog()),
		telemetrypkg.DefaultCatalog(),
		&telemetrypkg.NoopRedisCache{},
		revokeTestAuthSecret,
	)
	client := &managementClientStub{}
	mux, closeServer := newTelemetryRevokeServer(t, client, service)
	defer closeServer()
	cookie := adminLoginCookie(t, mux)

	revoke := serveAdminRequest(mux, http.MethodPost, PathRevokeDevice+"without-telemetry-credential/revoke", cookie)
	if revoke.Code != http.StatusNoContent {
		t.Fatalf("revoke status = %d, want 204: %s", revoke.Code, revoke.Body.String())
	}
	if client.revokeCalls != 1 {
		t.Fatalf("Relay revoke calls = %d, want 1", client.revokeCalls)
	}
}

func TestAdminRevokeRemainsAvailableWhenTelemetryIsNotConfigured(t *testing.T) {
	client := &managementClientStub{}
	mux := newManagementEndpointServer(t, client, 2)
	cookie := adminLoginCookie(t, mux)

	revoke := serveAdminRequest(mux, http.MethodPost, PathRevokeDevice+"telemetry-omitted/revoke", cookie)
	if revoke.Code != http.StatusNoContent {
		t.Fatalf("revoke status = %d, want 204: %s", revoke.Code, revoke.Body.String())
	}
	if client.revokeCalls != 1 {
		t.Fatalf("Relay revoke calls = %d, want 1", client.revokeCalls)
	}
}

type revokeFailureStore struct {
	*telemetrypkg.MemoryStore
	err error
}

func (s *revokeFailureStore) RevokeDeviceCredential(context.Context, string) error {
	return s.err
}
