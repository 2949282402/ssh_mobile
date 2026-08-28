package telemetry_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

// Auth Flow Tests
// ---------------------------------------------------------------

func TestAuthenticateDevice_FailClosedWithoutSecret(t *testing.T) {
	ctx := context.Background()
	service, store := newTestService("")
	_, deviceHash := registerDevice(t, store, "dev-fail-closed")

	token, exp, err := service.AuthenticateDevice(ctx, "dev-fail-closed", deviceProof("dev-fail-closed", deviceHash, futureEpoch()), futureEpoch())
	if !errors.Is(err, ErrServiceUnavailable) {
		t.Fatalf("expected ErrServiceUnavailable without a token secret, got %v", err)
	}
	if token != "" || exp != 0 {
		t.Fatalf("expected empty token and zero expiry, got token=%q exp=%d", token, exp)
	}
	if service.Available() {
		t.Fatal("expected service to be unavailable (fail-closed) without a secret")
	}
}

func TestAuthenticateDevice_UnregisteredDeviceRejected(t *testing.T) {
	ctx := context.Background()
	service, _ := newTestService(testAuthSecret)

	token, exp, err := service.AuthenticateDevice(ctx, "dev-not-registered", "deadbeef", futureEpoch())
	if !errors.Is(err, ErrDeviceNotRegistered) {
		t.Fatalf("expected ErrDeviceNotRegistered, got %v", err)
	}
	if token != "" || exp != 0 {
		t.Fatalf("expected empty token, got token=%q exp=%d", token, exp)
	}
}

func TestAuthenticateDevice_WrongSignatureRejected(t *testing.T) {
	ctx := context.Background()
	service, store := newTestService(testAuthSecret)
	_, deviceHash := registerDevice(t, store, "dev-wrong-sig")

	// Compute a valid proof then corrupt it.
	exp := futureEpoch()
	wrongProof := deviceProof("dev-wrong-sig", deviceHash, exp)
	if strings.HasPrefix(wrongProof, "0") {
		wrongProof = "1" + wrongProof[1:]
	} else {
		wrongProof = "0" + wrongProof[1:]
	}

	token, expOut, err := service.AuthenticateDevice(ctx, "dev-wrong-sig", wrongProof, exp)
	if !errors.Is(err, ErrAuthFailed) {
		t.Fatalf("expected ErrAuthFailed for wrong signature, got %v", err)
	}
	if token != "" || expOut != 0 {
		t.Fatalf("expected empty token, got token=%q exp=%d", token, expOut)
	}
}

func TestAuthenticateDevice_ExpiredOrFutureEpochRejected(t *testing.T) {
	ctx := context.Background()
	service, store := newTestService(testAuthSecret)
	_, deviceHash := registerDevice(t, store, "dev-skew")

	tooOld := time.Now().UTC().Add(-10 * time.Minute).Unix()
	tooNew := time.Now().UTC().Add(10 * time.Minute).Unix()

	for _, badExp := range []int64{tooOld, tooNew} {
		proof := deviceProof("dev-skew", deviceHash, badExp)
		token, expOut, err := service.AuthenticateDevice(ctx, "dev-skew", proof, badExp)
		if !errors.Is(err, ErrAuthFailed) {
			t.Fatalf("expected ErrAuthFailed for expEpoch=%d, got %v", badExp, err)
		}
		if token != "" || expOut != 0 {
			t.Fatalf("expected empty token for expEpoch=%d, got token=%q exp=%d", badExp, token, expOut)
		}
	}
}

func TestAuthenticateDevice_ValidProofIssuesToken(t *testing.T) {
	ctx := context.Background()
	service, store := newTestService(testAuthSecret)
	_, deviceHash := registerDevice(t, store, "dev-valid")

	exp := futureEpoch()
	token, expiresIn, err := service.AuthenticateDevice(ctx, "dev-valid", deviceProof("dev-valid", deviceHash, exp), exp)
	if err != nil {
		t.Fatalf("expected successful auth, got %v", err)
	}
	if token == "" {
		t.Fatal("expected a non-empty token")
	}
	if expiresIn <= 0 || expiresIn > int64(DefaultTokenTTL/time.Second) {
		t.Fatalf("unexpected expiresIn=%d (DefaultTokenTTL=%s)", expiresIn, DefaultTokenTTL)
	}
	if !service.VerifyDeviceToken("dev-valid", token) {
		t.Fatal("expected issued token to verify")
	}
	if service.VerifyDeviceToken("dev-someone-else", token) {
		t.Fatal("expected token bound to dev-valid to fail for another device")
	}
}

func TestVerifyDeviceToken_NoSecretFails(t *testing.T) {
	service, _ := newTestService("")
	token, exp := service.GenerateDeviceToken("dev-x", DefaultTokenTTL)
	if token != "" || exp != 0 {
		t.Fatalf("expected no token and zero expiry when signing key is missing, got token=%q exp=%d", token, exp)
	}
	if service.VerifyDeviceToken("dev-x", "whatever") {
		t.Fatal("expected verification to fail without a signing key")
	}
}

func TestVerifyDeviceToken_LegacySinglePartTokenRejected(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	_, deviceHash := registerDevice(t, store, "dev-legacy")
	_ = deviceHash

	// A single-part token (old simple hash fallback) must NEVER verify.
	bad := "abcdef0123456789abcdef0123456789"
	if service.VerifyDeviceToken("dev-legacy", bad) {
		t.Fatal("expected legacy single-part token to be rejected")
	}
}

func TestVerifyDeviceToken_ExpiredTokenRejected(t *testing.T) {
	service, _ := newTestService(testAuthSecret)
	// The public generator truncates to Unix seconds; a sub-second lifetime
	// produces a token that is already expired without reaching private signing
	// helpers or sleeping for a full token lifetime.
	token, exp := service.GenerateDeviceToken("dev-expired", time.Nanosecond)
	if exp <= 0 {
		t.Fatalf("expected a generated expiry, got %d", exp)
	}
	if service.VerifyDeviceToken("dev-expired", token) {
		t.Fatal("expected expired token to be rejected")
	}
}

// HandlePublicAuth HTTP tests
// ---------------------------------------------------------------

func TestHandlePublicAuth_UnregisteredDeviceReturns401(t *testing.T) {
	service, _ := newTestService(testAuthSecret)
	handler := NewHandler(service)
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	body, _ := json.Marshal(map[string]any{
		"deviceId": "dev-nope",
		"proof":    "beef",
		"expEpoch": futureEpoch(),
	})
	req := httptest.NewRequest(http.MethodPost, PathPublicAuth, bytes.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for unregistered device, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "DEVICE_NOT_REGISTERED") {
		t.Fatalf("expected DEVICE_NOT_REGISTERED error code, got %s", rec.Body.String())
	}
}

func TestHandlePublicAuth_ServiceUnavailableReturns503(t *testing.T) {
	// No store and no secret -> fail-closed 503.
	service := NewService(nil, DefaultCatalog(), &NoopRedisCache{})
	handler := NewHandler(service)
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	body, _ := json.Marshal(map[string]any{
		"deviceId": "dev-x",
		"proof":    "beef",
		"expEpoch": futureEpoch(),
	})
	req := httptest.NewRequest(http.MethodPost, PathPublicAuth, bytes.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 when service unavailable, got %d", rec.Code)
	}
}

// HandlePublicIngest HTTP tests
// ---------------------------------------------------------------

func testEnvelope(eventID, deviceID string) TelemetryEnvelope {
	now := time.Now().UTC()
	return TelemetryEnvelope{
		EventID:      eventID,
		RecordType:   RecordTypeAnalytics,
		EventName:    "ssh.session.started",
		EventVersion: 1,
		DeviceID:     deviceID,
		SessionID:    "sess-" + eventID,
		TraceID:      "trace-" + eventID,
		OccurredAt:   now,
		ReceivedAt:   now.Add(-24 * time.Hour), // client-supplied; must be ignored
		Feature:      "ssh",
		Severity:     SeverityInfo,
		AppVersion:   "1.0.0",
		BuildNumber:  "100",
		Platform:     "android",
		Properties:   map[string]any{"session_type": "interactive"},
	}
}

func mustAuth(t *testing.T, service *Service, store *MemoryStore, deviceID string) string {
	t.Helper()
	_, deviceHash := registerDevice(t, store, deviceID)
	exp := futureEpoch()
	token, _, err := service.AuthenticateDevice(context.Background(), deviceID, deviceProof(deviceID, deviceHash, exp), exp)
	if err != nil {
		t.Fatalf("failed to auth device %s: %v", deviceID, err)
	}
	return token
}

func TestHandlePublicIngest_DeviceMismatchReturns401(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	handler := NewHandler(service)
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	tokenA := mustAuth(t, service, store, "dev-a")
	batch := IngestBatchRequest{Records: []TelemetryEnvelope{testEnvelope("evt-mismatch", "dev-a")}}
	body, _ := json.Marshal(batch)

	req := httptest.NewRequest(http.MethodPost, PathPublicIngest, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+tokenA)
	req.Header.Set("X-Device-Id", "dev-b") // mismatch token binding
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 on device mismatch, got %d", rec.Code)
	}
}

func TestHandlePublicIngest_InvalidTokenReturns401(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	handler := NewHandler(service)
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	_ = store // no credential needed; tampered token must fail

	batch := IngestBatchRequest{Records: []TelemetryEnvelope{testEnvelope("evt-badtoken", "dev-x")}}
	body, _ := json.Marshal(batch)

	req := httptest.NewRequest(http.MethodPost, PathPublicIngest, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer 12345.bogus-signature")
	req.Header.Set("X-Device-Id", "dev-x")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 on invalid token, got %d", rec.Code)
	}
}

func TestHandlePublicIngest_ServerStampsReceivedAt(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	handler := NewHandler(service)
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	deviceID := "dev-recv"
	token := mustAuth(t, service, store, deviceID)

	before := time.Now().UTC()
	batch := IngestBatchRequest{Records: []TelemetryEnvelope{testEnvelope("evt-recv", deviceID)}}
	body, _ := json.Marshal(batch)

	req := httptest.NewRequest(http.MethodPost, PathPublicIngest, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-Device-Id", deviceID)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	after := time.Now().UTC()

	events, total, err := store.QueryEvents(context.Background(), QueryFilter{DeviceID: deviceID})
	if err != nil || total != 1 {
		t.Fatalf("expected 1 stored event, got total=%d err=%v", total, err)
	}
	stored := events[0].ReceivedAt
	if stored.Before(before) || stored.After(after) {
		t.Fatalf("expected server-stamped receivedAt in [%v, %v], got %v", before, after, stored)
	}
	if stored.Sub(before) > time.Minute || before.Sub(stored) > time.Minute {
		t.Fatalf("receivedAt %v is not near server now %v", stored, before)
	}
}

func TestHandlePublicIngest_MysqlDownReturns503(t *testing.T) {
	// A store that fails every ingest operation propagates an error -> 503.
	failing := &failingIngestStore{}
	service := NewServiceWithSecret(failing, DefaultCatalog(), &NoopRedisCache{}, testAuthSecret)
	handler := NewHandler(service)
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	// Register credential against the failing store.
	deviceID := "dev-mysql-down"
	if err := failing.RegisterDeviceCredential(context.Background(), deviceID, "hash"); err != nil {
		t.Fatalf("register: %v", err)
	}

	exp := futureEpoch()
	proof := deviceProof(deviceID, "hash", exp)
	token, _, err := service.AuthenticateDevice(context.Background(), deviceID, proof, exp)
	if err != nil {
		t.Fatalf("auth failed: %v", err)
	}

	batch := IngestBatchRequest{Records: []TelemetryEnvelope{testEnvelope("evt-down", deviceID)}}
	body, _ := json.Marshal(batch)
	req := httptest.NewRequest(http.MethodPost, PathPublicIngest, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-Device-Id", deviceID)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 when the backing store is down, got %d: %s", rec.Code, rec.Body.String())
	}
}

// MySQL-down store used to simulate backing store failure.
type failingIngestStore struct{}

func (f *failingIngestStore) IngestBatch(ctx context.Context, envelopes []TelemetryEnvelope) ([]IngestRecordResult, error) {
	return nil, errors.New("mysql connection refused")
}
func (f *failingIngestStore) QueryOverview(ctx context.Context, filter QueryFilter) (*OverviewMetrics, error) {
	return nil, errors.New("mysql connection refused")
}
func (f *failingIngestStore) QueryEvents(ctx context.Context, filter QueryFilter) ([]TelemetryEnvelope, int, error) {
	return nil, 0, errors.New("mysql connection refused")
}
func (f *failingIngestStore) QueryDiagnostics(ctx context.Context, filter QueryFilter) ([]TelemetryEnvelope, int, error) {
	return nil, 0, errors.New("mysql connection refused")
}
func (f *failingIngestStore) GetSettings(ctx context.Context) (*TelemetrySettings, error) {
	return nil, errors.New("mysql connection refused")
}
func (f *failingIngestStore) SaveSettings(ctx context.Context, settings TelemetrySettings) error {
	return errors.New("mysql connection refused")
}
func (f *failingIngestStore) PurgeRetention(ctx context.Context, cutoff time.Time, maxRows int, batchSize int) (int, error) {
	return 0, errors.New("mysql connection refused")
}
func (f *failingIngestStore) RegisterDeviceCredential(ctx context.Context, deviceID, secretHash string) error {
	return nil
}
func (f *failingIngestStore) GetDeviceCredential(ctx context.Context, deviceID string) (string, error) {
	return "hash", nil
}
func (f *failingIngestStore) Close() error { return nil }

// Refresh: re-authenticating with a current epoch issues a fresh token.
func TestAuthenticateDevice_RefreshIssuesNewToken(t *testing.T) {
	ctx := context.Background()
	service, store := newTestService(testAuthSecret)
	_, deviceHash := registerDevice(t, store, "dev-refresh")

	exp1 := futureEpoch()
	token1, _, err := service.AuthenticateDevice(ctx, "dev-refresh", deviceProof("dev-refresh", deviceHash, exp1), exp1)
	if err != nil {
		t.Fatalf("first auth failed: %v", err)
	}
	valid := service.VerifyDeviceToken("dev-refresh", token1)
	time.Sleep(1100 * time.Millisecond) // advance epoch so issued token timestamp differs
	exp2 := futureEpoch()
	token2, _, err := service.AuthenticateDevice(ctx, "dev-refresh", deviceProof("dev-refresh", deviceHash, exp2), exp2)
	if err != nil {
		t.Fatalf("refresh auth failed: %v", err)
	}
	if token1 == token2 {
		t.Fatal("expected a different token after refreshing with a new epoch")
	}
	if !valid || !service.VerifyDeviceToken("dev-refresh", token2) {
		t.Fatal("expected both tokens to verify")
	}
}
