package telemetry_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestTelemetryHTTPHandler(t *testing.T) {
	catalog := DefaultCatalog()
	store := NewMemoryStore(catalog)
	service := NewServiceWithSecret(store, catalog, &NoopRedisCache{}, testAuthSecret)
	handler := NewHandler(service)

	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	// Register the device credential first so auth can succeed.
	_, deviceHash := registerDevice(t, store, "dev_test_123")
	expEpoch := futureEpoch()

	// 1. Device Auth Flow (proof-of-possession of registered secret)
	authReqBody, _ := json.Marshal(map[string]any{
		"deviceId": "dev_test_123",
		"proof":    deviceProof("dev_test_123", deviceHash, expEpoch),
		"expEpoch": expEpoch,
	})
	authReq := httptest.NewRequest(http.MethodPost, "/api/v1/telemetry/auth", bytes.NewReader(authReqBody))
	authReq.Header.Set("Content-Type", "application/json")
	authRec := httptest.NewRecorder()
	mux.ServeHTTP(authRec, authReq)

	if authRec.Code != http.StatusOK {
		t.Fatalf("expected 200 OK from auth, got %d: %s", authRec.Code, authRec.Body.String())
	}

	var authResp map[string]any
	_ = json.Unmarshal(authRec.Body.Bytes(), &authResp)
	token, ok := authResp["token"].(string)
	if !ok || token == "" {
		t.Fatalf("expected valid token in auth response, got %v", authResp)
	}

	// 2. Policy Fetch
	policyReq := httptest.NewRequest(http.MethodGet, "/api/v1/telemetry/policy", nil)
	policyRec := httptest.NewRecorder()
	mux.ServeHTTP(policyRec, policyReq)

	if policyRec.Code != http.StatusOK {
		t.Fatalf("expected 200 OK from policy, got %d", policyRec.Code)
	}

	var policyResp TelemetryUploadPolicy
	if err := json.Unmarshal(policyRec.Body.Bytes(), &policyResp); err != nil {
		t.Fatalf("unmarshal policy error: %v", err)
	}
	if !policyResp.UploadEnabled || policyResp.BatchSizeThreshold != 50 {
		t.Errorf("unexpected policy: %+v", policyResp)
	}

	// 3. Ingest Batch without Auth -> MUST return 401 Unauthorized
	batch := IngestBatchRequest{
		Records: []TelemetryEnvelope{
			{
				EventID:      "evt-h-1",
				RecordType:   RecordTypeAnalytics,
				EventName:    "ssh.session.started",
				EventVersion: 1,
				DeviceID:     "dev_test_123",
				SessionID:    "sess_1",
				TraceID:      "trace_1",
				OccurredAt:   time.Now().UTC(),
				Feature:      "ssh",
				Severity:     SeverityInfo,
				AppVersion:   "1.0.0",
				BuildNumber:  "100",
				Platform:     "android",
				Properties:   map[string]any{"session_type": "interactive"},
			},
		},
	}
	bodyBytes, _ := json.Marshal(batch)

	unauthReq := httptest.NewRequest(http.MethodPost, "/api/v1/telemetry/ingest", bytes.NewReader(bodyBytes))
	unauthReq.Header.Set("Content-Type", "application/json")
	unauthRec := httptest.NewRecorder()
	mux.ServeHTTP(unauthRec, unauthReq)

	if unauthRec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401 Unauthorized without auth header, got %d", unauthRec.Code)
	}

	// 4. Ingest Batch with Valid Auth Header
	ingestReq := httptest.NewRequest(http.MethodPost, "/api/v1/telemetry/ingest", bytes.NewReader(bodyBytes))
	ingestReq.Header.Set("Content-Type", "application/json")
	ingestReq.Header.Set("Authorization", "Bearer "+token)
	ingestReq.Header.Set("X-Device-Id", "dev_test_123")
	ingestRec := httptest.NewRecorder()
	mux.ServeHTTP(ingestRec, ingestReq)

	if ingestRec.Code != http.StatusOK {
		t.Fatalf("expected 200 OK from ingest, got %d: %s", ingestRec.Code, ingestRec.Body.String())
	}

	var ingestResp IngestBatchResponse
	if err := json.Unmarshal(ingestRec.Body.Bytes(), &ingestResp); err != nil {
		t.Fatalf("unmarshal ingest response error: %v", err)
	}
	if len(ingestResp.Results) != 1 || ingestResp.Results[0].Status != StatusAccepted {
		t.Fatalf("expected accepted result, got %+v", ingestResp)
	}

	// 5. Ingest Replay -> returns already_seen
	replayReq := httptest.NewRequest(http.MethodPost, "/api/v1/telemetry/ingest", bytes.NewReader(bodyBytes))
	replayReq.Header.Set("Content-Type", "application/json")
	replayReq.Header.Set("Authorization", "Bearer "+token)
	replayReq.Header.Set("X-Device-Id", "dev_test_123")
	replayRec := httptest.NewRecorder()
	mux.ServeHTTP(replayRec, replayReq)

	var replayResp IngestBatchResponse
	_ = json.Unmarshal(replayRec.Body.Bytes(), &replayResp)
	if len(replayResp.Results) != 1 || replayResp.Results[0].Status != StatusAlreadySeen {
		t.Fatalf("expected already_seen on replay, got %+v", replayResp)
	}
}

func TestTelemetryAdminHTTPHandlers(t *testing.T) {
	catalog := DefaultCatalog()
	store := NewMemoryStore(catalog)
	service := NewServiceWithSecret(store, catalog, &NoopRedisCache{}, testAuthSecret)
	handler := NewHandler(service)

	mux := http.NewServeMux()
	handler.RegisterAdminRoutes(mux, func(next http.HandlerFunc) http.HandlerFunc {
		// Mock pass-through admin auth middleware for test
		return next
	})

	now := time.Now().UTC()
	_, _ = store.IngestBatch(nil, []TelemetryEnvelope{
		{
			EventID:      "evt-adm-1",
			RecordType:   RecordTypeAnalytics,
			EventName:    "ssh.session.started",
			EventVersion: 1,
			DeviceID:     "dev-adm-1",
			SessionID:    "sess-1",
			TraceID:      "trace-1",
			OccurredAt:   now,
			Feature:      "ssh",
			Severity:     SeverityInfo,
			AppVersion:   "1.0.0",
			BuildNumber:  "100",
			Platform:     "android",
		},
		{
			EventID:      "diag-adm-2",
			RecordType:   RecordTypeDiagnostic,
			EventName:    "ssh.session.failed",
			EventVersion: 1,
			DeviceID:     "dev-adm-1",
			SessionID:    "sess-1",
			TraceID:      "trace-1",
			OccurredAt:   now,
			Feature:      "ssh",
			Severity:     SeverityError,
			AppVersion:   "1.0.0",
			BuildNumber:  "100",
			Platform:     "android",
			Error: &TelemetryError{
				ErrorCode:       "SSH_TIMEOUT",
				Category:        "ssh",
				TerminalFailure: true,
			},
		},
	})

	// 1. GET /api/admin/v1/telemetry/overview
	ovReq := httptest.NewRequest(http.MethodGet, "/api/admin/v1/telemetry/overview?timeRange=24h", nil)
	ovRec := httptest.NewRecorder()
	mux.ServeHTTP(ovRec, ovReq)
	if ovRec.Code != http.StatusOK {
		t.Fatalf("expected 200 from overview, got %d: %s", ovRec.Code, ovRec.Body.String())
	}
	var ovResp OverviewMetrics
	_ = json.Unmarshal(ovRec.Body.Bytes(), &ovResp)
	if ovResp.TotalEvents != 1 || ovResp.TotalDiagnostics != 1 || ovResp.ErrorCount != 1 {
		t.Errorf("unexpected overview metrics: %+v", ovResp)
	}

	// Test 1h filter vs empty future window
	futureReq := httptest.NewRequest(http.MethodGet, "/api/admin/v1/telemetry/overview?startTime=2099-01-01T00:00:00Z", nil)
	futureRec := httptest.NewRecorder()
	mux.ServeHTTP(futureRec, futureReq)
	var futureResp OverviewMetrics
	_ = json.Unmarshal(futureRec.Body.Bytes(), &futureResp)
	if futureResp.TotalEvents != 0 {
		t.Errorf("expected 0 events in future window, got %d", futureResp.TotalEvents)
	}

	// 2. GET /api/admin/v1/telemetry/events
	evReq := httptest.NewRequest(http.MethodGet, "/api/admin/v1/telemetry/events?deviceId=dev-adm-1", nil)
	evRec := httptest.NewRecorder()
	mux.ServeHTTP(evRec, evReq)
	if evRec.Code != http.StatusOK {
		t.Fatalf("expected 200 from events list, got %d", evRec.Code)
	}

	// 3. GET /api/admin/v1/telemetry/diagnostics
	diagReq := httptest.NewRequest(http.MethodGet, "/api/admin/v1/telemetry/diagnostics", nil)
	diagRec := httptest.NewRecorder()
	mux.ServeHTTP(diagRec, diagReq)
	if diagRec.Code != http.StatusOK {
		t.Fatalf("expected 200 from diagnostics list, got %d", diagRec.Code)
	}

	// 4. GET & PUT /api/admin/v1/telemetry/settings
	setReq := httptest.NewRequest(http.MethodGet, "/api/admin/v1/telemetry/settings", nil)
	setRec := httptest.NewRecorder()
	mux.ServeHTTP(setRec, setReq)
	if setRec.Code != http.StatusOK {
		t.Fatalf("expected 200 from settings GET, got %d", setRec.Code)
	}

	updatedSettings := DefaultSettings()
	updatedSettings.RetentionDays = 60
	setBody, _ := json.Marshal(updatedSettings)
	putReq := httptest.NewRequest(http.MethodPut, "/api/admin/v1/telemetry/settings", bytes.NewReader(setBody))
	putReq.Header.Set("Content-Type", "application/json")
	putRec := httptest.NewRecorder()
	mux.ServeHTTP(putRec, putReq)
	if putRec.Code != http.StatusOK {
		t.Fatalf("expected 200 from settings PUT, got %d: %s", putRec.Code, putRec.Body.String())
	}
}

func TestTelemetryAdminRegisterDevice(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	handler := NewHandler(service)

	mux := http.NewServeMux()
	handler.RegisterAdminRoutes(mux, func(next http.HandlerFunc) http.HandlerFunc {
		return next
	})

	regBody, _ := json.Marshal(map[string]string{"deviceId": "dev-enrolled"})
	req := httptest.NewRequest(http.MethodPost, PathAdminRegisterDevice, bytes.NewReader(regBody))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201 from register device, got %d: %s", rec.Code, rec.Body.String())
	}

	var resp struct {
		DeviceID string `json:"deviceId"`
		Secret   string `json:"secret"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode register response: %v", err)
	}
	if resp.DeviceID != "dev-enrolled" || len(resp.Secret) != 64 {
		t.Fatalf("unexpected register response: %+v", resp)
	}

	// The credential hash is stored; the returned secret can authenticate.
	storedHash, err := store.GetDeviceCredential(context.Background(), "dev-enrolled")
	if err != nil {
		t.Fatalf("expected stored credential: %v", err)
	}
	if storedHash != hashSecret(resp.Secret) {
		t.Fatal("stored hash does not match generated secret")
	}

	ctx := context.Background()
	exp := futureEpoch()
	token, _, err := service.AuthenticateDevice(ctx, "dev-enrolled", deviceProof("dev-enrolled", storedHash, exp), exp)
	if err != nil {
		t.Fatalf("expected enrolled device to authenticate with generated secret: %v", err)
	}
	if !service.VerifyDeviceToken("dev-enrolled", token) {
		t.Fatal("expected token to verify")
	}

	// Re-registration is idempotent (upsert), returns a NEW secret hash.
	req2 := httptest.NewRequest(http.MethodPost, PathAdminRegisterDevice, bytes.NewReader(regBody))
	req2.Header.Set("Content-Type", "application/json")
	rec2 := httptest.NewRecorder()
	mux.ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusCreated {
		t.Fatalf("expected 201 from repeat registration, got %d", rec2.Code)
	}
	var resp2 struct {
		Secret string `json:"secret"`
	}
	_ = json.Unmarshal(rec2.Body.Bytes(), &resp2)
	if resp2.Secret == resp.Secret {
		t.Fatal("expected a fresh secret on re-registration")
	}
}
