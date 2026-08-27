// Comprehensive End-to-End Integration Verification for Telemetry System.

package telemetry

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestTelemetry_EndToEnd_SystemLifecycle(t *testing.T) {
	ctx := context.Background()

	// 1. Initialize Telemetry catalog, memory store, and Redis diagnostic cache
	catalog := DefaultCatalog()
	store := NewMemoryStore(catalog)
	defer store.Close()

	redisCache := &NoopRedisCache{}
	service := NewService(store, catalog, redisCache)
	handler := NewHandler(service)

	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)
	handler.RegisterAdminRoutes(mux, func(next http.HandlerFunc) http.HandlerFunc {
		return next
	})
	server := httptest.NewServer(mux)
	defer server.Close()

	deviceID := "device-e2e-client-1"
	var bearerToken string

	// 2. Client Device Authentication (/api/v1/telemetry/auth)
	t.Run("1_Device_Authentication", func(t *testing.T) {
		authBody, _ := json.Marshal(map[string]string{
			"deviceId": deviceID,
		})
		resp, err := http.Post(server.URL+PathPublicAuth, "application/json", bytes.NewReader(authBody))
		if err != nil {
			t.Fatalf("auth request failed: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			t.Fatalf("expected status 200, got %d", resp.StatusCode)
		}
		var authResp map[string]any
		if err := json.NewDecoder(resp.Body).Decode(&authResp); err != nil {
			t.Fatalf("failed to decode auth response: %v", err)
		}
		token, ok := authResp["token"].(string)
		if !ok || token == "" {
			t.Fatalf("expected valid token, got %v", authResp)
		}
		bearerToken = token
	})

	// 3. Fetch Client Dynamic Upload Policy (/api/v1/telemetry/policy)
	t.Run("2_Fetch_Dynamic_Policy", func(t *testing.T) {
		resp, err := http.Get(server.URL + PathPublicPolicy)
		if err != nil {
			t.Fatalf("policy request failed: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			t.Fatalf("expected status 200, got %d", resp.StatusCode)
		}
		var policy TelemetryUploadPolicy
		if err := json.NewDecoder(resp.Body).Decode(&policy); err != nil {
			t.Fatalf("failed to decode policy: %v", err)
		}
		if !policy.UploadEnabled || policy.BatchSizeThreshold != 50 || policy.PolicyVersion != 1 {
			t.Fatalf("unexpected policy values: %+v", policy)
		}
	})

	// 4. Client Batch Ingestion with Signature & Idempotency (/api/v1/telemetry/ingest)
	t.Run("3_Batch_Ingest_With_Auth_And_Idempotency", func(t *testing.T) {
		batchReq := IngestBatchRequest{
			Records: []TelemetryEnvelope{
				{
					EventID:      "evt-e2e-001",
					RecordType:   RecordTypeAnalytics,
					EventName:    "ssh.session.started",
					EventVersion: 1,
					DeviceID:     deviceID,
					SessionID:    "sess-e2e-001",
					TraceID:      "trace-e2e-001",
					OccurredAt:   time.Now().UTC(),
					Feature:      "ssh",
					Severity:     SeverityInfo,
					AppVersion:   "1.0.0",
					BuildNumber:  "100",
					Platform:     "android",
					Properties:   map[string]any{"session_type": "interactive", "auth_method": "key"},
				},
				{
					EventID:      "evt-e2e-002",
					RecordType:   RecordTypeDiagnostic,
					EventName:    "ssh.session.failed",
					EventVersion: 1,
					DeviceID:     deviceID,
					SessionID:    "sess-e2e-001",
					TraceID:      "trace-e2e-002",
					OccurredAt:   time.Now().UTC(),
					Feature:      "ssh",
					Severity:     SeverityError,
					AppVersion:   "1.0.0",
					BuildNumber:  "100",
					Platform:     "android",
					Properties:   map[string]any{"stage": "handshake", "retry_count": 2},
					Error: &TelemetryError{
						ErrorCode:       "SSH_AUTH_FAILED",
						Category:        "ssh",
						TerminalFailure: true,
						Message:         "Permission denied (publickey)",
						StackTrace:      "Stacktrace line 1\nStacktrace line 2",
					},
				},
			},
		}

		payloadBytes, err := json.Marshal(batchReq)
		if err != nil {
			t.Fatalf("failed to marshal batch: %v", err)
		}

		req, err := http.NewRequest(http.MethodPost, server.URL+PathPublicIngest, bytes.NewReader(payloadBytes))
		if err != nil {
			t.Fatalf("failed to create ingest request: %v", err)
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Device-Id", deviceID)
		req.Header.Set("Authorization", "Bearer "+bearerToken)

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("ingest request failed: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			t.Fatalf("expected status 200, got %d", resp.StatusCode)
		}
		var ingestResp IngestBatchResponse
		if err := json.NewDecoder(resp.Body).Decode(&ingestResp); err != nil {
			t.Fatalf("failed to decode ingest response: %v", err)
		}
		if len(ingestResp.Results) != 2 {
			t.Fatalf("expected 2 results, got %d", len(ingestResp.Results))
		}
		if ingestResp.Results[0].Status != StatusAccepted || ingestResp.Results[1].Status != StatusAccepted {
			t.Fatalf("expected both accepted, got %+v", ingestResp.Results)
		}

		// Resend the exact same batch to test idempotent receipt verification (Durable Receipts)
		req2, err := http.NewRequest(http.MethodPost, server.URL+PathPublicIngest, bytes.NewReader(payloadBytes))
		if err != nil {
			t.Fatalf("failed to create req2: %v", err)
		}
		req2.Header.Set("Content-Type", "application/json")
		req2.Header.Set("X-Device-Id", deviceID)
		req2.Header.Set("Authorization", "Bearer "+bearerToken)

		resp2, err := http.DefaultClient.Do(req2)
		if err != nil {
			t.Fatalf("req2 failed: %v", err)
		}
		defer resp2.Body.Close()

		if resp2.StatusCode != http.StatusOK {
			t.Fatalf("expected status 200, got %d", resp2.StatusCode)
		}
		var ingestResp2 IngestBatchResponse
		if err := json.NewDecoder(resp2.Body).Decode(&ingestResp2); err != nil {
			t.Fatalf("failed to decode resp2: %v", err)
		}
		if len(ingestResp2.Results) != 2 {
			t.Fatalf("expected 2 results, got %d", len(ingestResp2.Results))
		}
		if ingestResp2.Results[0].Status != StatusAlreadySeen || ingestResp2.Results[1].Status != StatusAlreadySeen {
			t.Fatalf("expected both already_seen on replay, got %+v", ingestResp2.Results)
		}
	})

	// 5. Admin Overview Metrics (/api/admin/v1/telemetry/overview)
	t.Run("4_Admin_Overview_Query", func(t *testing.T) {
		resp, err := http.Get(server.URL + PathAdminOverview + "?timeRange=24h")
		if err != nil {
			t.Fatalf("overview request failed: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			t.Fatalf("expected status 200, got %d", resp.StatusCode)
		}
		var metrics OverviewMetrics
		if err := json.NewDecoder(resp.Body).Decode(&metrics); err != nil {
			t.Fatalf("failed to decode overview metrics: %v", err)
		}

		if metrics.TotalEvents != 1 || metrics.TotalDiagnostics != 1 || metrics.RecentActiveDevices != 1 {
			t.Fatalf("unexpected overview metrics: %+v", metrics)
		}
		if metrics.PipelineHealth.Status != "healthy" && metrics.PipelineHealth.Status != "degraded" {
			t.Fatalf("expected pipeline healthy or degraded, got %s", metrics.PipelineHealth.Status)
		}
	})

	// 6. Admin Event Explorer Query (/api/admin/v1/telemetry/events)
	t.Run("5_Admin_Events_Query", func(t *testing.T) {
		resp, err := http.Get(server.URL + PathAdminEvents + "?eventName=ssh.session.started")
		if err != nil {
			t.Fatalf("events request failed: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			t.Fatalf("expected status 200, got %d", resp.StatusCode)
		}
		var result struct {
			Items []TelemetryEnvelope `json:"items"`
			Total int                 `json:"total"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
			t.Fatalf("failed to decode events: %v", err)
		}
		if result.Total != 1 || len(result.Items) != 1 || result.Items[0].EventID != "evt-e2e-001" {
			t.Fatalf("unexpected events query result: %+v", result)
		}
	})

	// 7. Admin Diagnostic Log Query (/api/admin/v1/telemetry/diagnostics)
	t.Run("6_Admin_Diagnostics_Query", func(t *testing.T) {
		resp, err := http.Get(server.URL + PathAdminDiagnostics + "?severity=error")
		if err != nil {
			t.Fatalf("diagnostics request failed: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			t.Fatalf("expected status 200, got %d", resp.StatusCode)
		}
		var result struct {
			Items  []TelemetryEnvelope `json:"items"`
			Total  int                 `json:"total"`
			Source string              `json:"source"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
			t.Fatalf("failed to decode diagnostics: %v", err)
		}
		if result.Total != 1 || len(result.Items) != 1 || result.Items[0].Error.ErrorCode != "SSH_AUTH_FAILED" {
			t.Fatalf("unexpected diagnostics query result: %+v", result)
		}
	})

	// 8. Admin Update Settings (/api/admin/v1/telemetry/settings)
	t.Run("7_Admin_Update_Settings", func(t *testing.T) {
		newSettings := DefaultSettings()
		newSettings.Policy.BatchSizeThreshold = 80
		newSettings.Policy.PolicyVersion = 2
		newSettings.RetentionDays = 45

		bodyBytes, _ := json.Marshal(newSettings)
		req, err := http.NewRequest(http.MethodPut, server.URL+PathAdminSettings, bytes.NewReader(bodyBytes))
		if err != nil {
			t.Fatalf("failed to create update settings request: %v", err)
		}
		req.Header.Set("Content-Type", "application/json")

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("update settings request failed: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			t.Fatalf("expected status 200, got %d", resp.StatusCode)
		}

		// Verify client policy now serves updated policyVersion = 2
		policyResp, err := http.Get(server.URL + PathPublicPolicy)
		if err != nil {
			t.Fatalf("policy req failed: %v", err)
		}
		defer policyResp.Body.Close()

		var updatedPolicy TelemetryUploadPolicy
		if err := json.NewDecoder(policyResp.Body).Decode(&updatedPolicy); err != nil {
			t.Fatalf("failed to decode updated policy: %v", err)
		}
		if updatedPolicy.BatchSizeThreshold != 80 || updatedPolicy.PolicyVersion != 2 {
			t.Fatalf("expected updated policy (80, v2), got %+v", updatedPolicy)
		}
	})

	// 9. Retention Cleaner Purge & Receipt Preservation
	t.Run("8_Retention_Purge_Preserves_Receipts", func(t *testing.T) {
		// Purge with future cutoff timestamp
		purged, err := store.PurgeRetention(ctx, time.Now().Add(24*time.Hour), 0, 100)
		if err != nil {
			t.Fatalf("purge failed: %v", err)
		}
		if purged != 2 {
			t.Fatalf("expected 2 purged, got %d", purged)
		}

		// Confirm raw events are cleared
		events, total, err := store.QueryEvents(ctx, QueryFilter{})
		if err != nil {
			t.Fatalf("query events failed: %v", err)
		}
		if total != 0 || len(events) != 0 {
			t.Fatalf("expected 0 events, got %d", total)
		}

		// Send same event again -> Must STILL be recognized as already_seen because receipts are permanent!
		batchReq := IngestBatchRequest{
			Records: []TelemetryEnvelope{
				{
					EventID:      "evt-e2e-001",
					RecordType:   RecordTypeAnalytics,
					EventName:    "ssh.session.started",
					EventVersion: 1,
					DeviceID:     deviceID,
					SessionID:    "sess-e2e-001",
					TraceID:      "trace-e2e-001",
					OccurredAt:   time.Now().UTC(),
					Feature:      "ssh",
					Severity:     SeverityInfo,
					AppVersion:   "1.0.0",
					BuildNumber:  "100",
					Platform:     "android",
					Properties:   map[string]any{"session_type": "interactive", "auth_method": "key"},
				},
			},
		}
		payloadBytes, err := json.Marshal(batchReq)
		if err != nil {
			t.Fatalf("failed to marshal: %v", err)
		}

		req, err := http.NewRequest(http.MethodPost, server.URL+PathPublicIngest, bytes.NewReader(payloadBytes))
		if err != nil {
			t.Fatalf("failed to create req: %v", err)
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Device-Id", deviceID)
		req.Header.Set("Authorization", "Bearer "+bearerToken)

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("request failed: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			t.Fatalf("expected status 200, got %d", resp.StatusCode)
		}
		var ingestResp IngestBatchResponse
		if err := json.NewDecoder(resp.Body).Decode(&ingestResp); err != nil {
			t.Fatalf("failed to decode: %v", err)
		}
		if len(ingestResp.Results) != 1 {
			t.Fatalf("expected 1 result, got %d", len(ingestResp.Results))
		}
		if ingestResp.Results[0].Status != StatusAlreadySeen {
			t.Fatalf("expected already_seen on re-upload after retention purge, got %s", ingestResp.Results[0].Status)
		}
	})
}
