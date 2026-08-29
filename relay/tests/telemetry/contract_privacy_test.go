package telemetry_test

import (
	"bytes"
	"context"
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestTelemetryJSONHandlersRejectUnknownFields(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	deviceID := "strict-json-device"
	token := mustAuth(t, service, store, deviceID)
	handler := NewHandler(service, &testDeviceAttestor{result: DeviceAttestation{DeviceID: deviceID}})
	mux := contractPrivacyMux(handler)

	tests := []struct {
		name   string
		method string
		path   string
		body   string
		auth   bool
	}{
		{
			name:   "public enrollment",
			method: http.MethodPost,
			path:   RoutePublicEnroll,
			body:   `{"deviceId":"strict-json-device","unknown":true}`,
		},
		{
			name:   "public enrollment requires an object",
			method: http.MethodPost,
			path:   RoutePublicEnroll,
			body:   `null`,
		},
		{
			name:   "public authentication",
			method: http.MethodPost,
			path:   RoutePublicAuth,
			body:   `{"deviceId":"strict-json-device","proof":"proof","expEpoch":1,"unknown":true}`,
		},
		{
			name:   "public ingest",
			method: http.MethodPost,
			path:   RoutePublicIngest,
			body:   `{"records":[],"unknown":true}`,
			auth:   true,
		},
		{
			name:   "admin settings",
			method: http.MethodPut,
			path:   PathAdminSettings,
			body:   `{"policy":{},"unknown":true}`,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
			req.Header.Set("Content-Type", "application/json")
			if tc.auth {
				req.Header.Set("Authorization", "Bearer "+token)
				req.Header.Set("X-Device-Id", deviceID)
			}
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("unknown field status = %d, want 400: %s", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestTelemetryIngestRejectsBodyDeviceMismatch(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	token := mustAuth(t, service, store, "authenticated-device")
	handler := NewHandler(service)
	mux := contractPrivacyMux(handler)

	record := testEnvelope("device-mismatch-body", "different-device")
	body, err := json.Marshal(IngestBatchRequest{Records: []TelemetryEnvelope{record}})
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, PathPublicIngest, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-Device-Id", "authenticated-device")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("body device mismatch status = %d, want 400: %s", rec.Code, rec.Body.String())
	}
	if _, total, err := store.QueryEvents(context.Background(), QueryFilter{}); err != nil {
		t.Fatalf("query events after mismatch: %v", err)
	} else if total != 0 {
		t.Fatalf("body mismatch persisted %d events", total)
	}
}

func TestTelemetryIngestBackfillsLegacyEnvelopeDeviceID(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	token := mustAuth(t, service, store, "authenticated-device")
	handler := NewHandler(service)
	mux := contractPrivacyMux(handler)

	record := testEnvelope("legacy-no-device-id", "authenticated-device")
	record.DeviceID = ""
	body, err := json.Marshal(IngestBatchRequest{Records: []TelemetryEnvelope{record}})
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, PathPublicIngest, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-Device-Id", "authenticated-device")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("legacy batch status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	var ingestResp IngestBatchResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &ingestResp); err != nil {
		t.Fatalf("decode ingest response: %v", err)
	}
	if len(ingestResp.Results) != 1 || ingestResp.Results[0].Status != StatusAccepted {
		t.Fatalf("legacy batch ACK = %#v, want accepted", ingestResp.Results)
	}

	rows, total, err := store.QueryEvents(context.Background(), QueryFilter{
		DeviceID: "authenticated-device",
		Page:     1,
		PageSize: 50,
	})
	if err != nil {
		t.Fatalf("query events after legacy backfill: %v", err)
	}
	if total != 1 || len(rows) != 1 || rows[0].DeviceID != "authenticated-device" {
		t.Fatalf("legacy backfilled rows = %#v total = %d, want one authenticated-device record", rows, total)
	}
}

func contractPrivacyMux(handler *Handler) *http.ServeMux {
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)
	handler.RegisterAdminRoutes(mux, func(next http.HandlerFunc) http.HandlerFunc { return next })
	return mux
}

func TestTelemetryCatalogValidatesDeclaredPrimitiveTypes(t *testing.T) {
	catalog := NewCatalog()
	catalog.RegisterEvent(EventDefinition{
		Name:       "test.primitive.types",
		Version:    1,
		RecordType: RecordTypeAnalytics,
		Feature:    "test",
		Severity:   SeverityInfo,
		AllowedProperties: []AllowedProperty{
			{Name: "label", Type: "string"},
			{Name: "count", Type: "integer"},
			{Name: "enabled", Type: "boolean"},
		},
	})

	valid := map[string]any{"label": "ok", "count": json.Number("2"), "enabled": true}
	if err := catalog.ValidateEvent("test.primitive.types", 1, valid); err != nil {
		t.Fatalf("valid primitive properties rejected: %v", err)
	}
	for _, tc := range []struct {
		name  string
		value any
	}{
		{name: "string", value: 2},
		{name: "integer", value: "2"},
		{name: "boolean", value: "true"},
		{name: "fractional number", value: 2.5},
	} {
		t.Run(tc.name, func(t *testing.T) {
			properties := map[string]any{"label": "ok", "count": 2, "enabled": true}
			switch tc.name {
			case "string":
				properties["label"] = tc.value
			case "integer", "fractional number":
				properties["count"] = tc.value
			case "boolean":
				properties["enabled"] = tc.value
			}
			if err := catalog.ValidateEvent("test.primitive.types", 1, properties); err == nil || !strings.Contains(err.Error(), "type") {
				t.Fatalf("wrong primitive was accepted or lacked type error: %v", err)
			}
		})
	}
}

func TestTelemetryCatalogRejectsUnsupportedDefinitionsAndMalformedJSON(t *testing.T) {
	validErrors := []byte(`{"version":"1","errorCodes":[]}`)
	unsupportedEvents := []byte(`{"version":"1","events":[{"name":"test.event","version":1,"recordType":"analytics","feature":"test","severity":"info","allowedProperties":[{"name":"value","type":"object","required":false}]}]}`)
	if _, err := LoadCatalogFromBytes(unsupportedEvents, validErrors); err == nil {
		t.Fatal("unsupported contract property type was accepted")
	}

	unknownFieldEvents := []byte(`{"version":"1","events":[],"unknown":true}`)
	if _, err := LoadCatalogFromBytes(unknownFieldEvents, validErrors); err == nil {
		t.Fatal("unknown contract field was accepted")
	}
	trailingEvents := []byte(`{"version":"1","events":[]} {}`)
	if _, err := LoadCatalogFromBytes(trailingEvents, validErrors); err == nil {
		t.Fatal("trailing contract JSON value was accepted")
	}

	catalog := NewCatalog()
	catalog.RegisterEvent(EventDefinition{
		Name:       "test.unsupported.definition",
		Version:    1,
		RecordType: RecordTypeAnalytics,
		Feature:    "test",
		Severity:   SeverityInfo,
		AllowedProperties: []AllowedProperty{
			{Name: "value", Type: "object"},
		},
	})
	if err := catalog.ValidateEvent("test.unsupported.definition", 1, nil); err == nil {
		t.Fatal("unsupported registered property type was accepted")
	}
}

func TestTelemetryCatalogAcceptsIntegerRepresentations(t *testing.T) {
	catalog := NewCatalog()
	catalog.RegisterEvent(EventDefinition{
		Name:       "test.integer.representations",
		Version:    1,
		RecordType: RecordTypeAnalytics,
		Feature:    "test",
		Severity:   SeverityInfo,
		AllowedProperties: []AllowedProperty{
			{Name: "value", Type: "integer"},
		},
	})

	valid := []struct {
		name  string
		value any
	}{
		{name: "int", value: int(1)},
		{name: "int8", value: int8(1)},
		{name: "int16", value: int16(1)},
		{name: "int32", value: int32(1)},
		{name: "int64", value: int64(1)},
		{name: "uint", value: uint(1)},
		{name: "uint8", value: uint8(1)},
		{name: "uint16", value: uint16(1)},
		{name: "uint32", value: uint32(1)},
		{name: "uint64", value: uint64(1)},
		{name: "json number", value: json.Number("1")},
		{name: "float32", value: float32(1)},
		{name: "float64", value: float64(1)},
	}
	for _, tc := range valid {
		t.Run(tc.name, func(t *testing.T) {
			if err := catalog.ValidateEvent("test.integer.representations", 1, map[string]any{"value": tc.value}); err != nil {
				t.Fatalf("integer representation rejected: %v", err)
			}
		})
	}

	invalid := []struct {
		name  string
		value any
	}{
		{name: "unsigned overflow", value: uint64(1 << 63)},
		{name: "fractional json number", value: json.Number("1.5")},
		{name: "fractional exponent json number", value: json.Number("1e-1")},
		{name: "fractional float", value: 1.5},
		{name: "nan", value: math.NaN()},
		{name: "infinity", value: math.Inf(1)},
		{name: "string", value: "1"},
	}
	for _, tc := range invalid {
		t.Run(tc.name, func(t *testing.T) {
			if err := catalog.ValidateEvent("test.integer.representations", 1, map[string]any{"value": tc.value}); err == nil {
				t.Fatal("invalid integer representation was accepted")
			}
		})
	}
}

func TestTelemetryServerRedactsAndBoundsDiagnosticText(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	envelope := TelemetryEnvelope{
		EventID:      "server-privacy-diagnostic",
		RecordType:   RecordTypeDiagnostic,
		EventName:    "app.error.captured",
		EventVersion: 1,
		DeviceID:     "privacy-device",
		SessionID:    "privacy-session",
		TraceID:      "privacy-trace",
		OccurredAt:   time.Now().UTC(),
		Feature:      "app",
		Severity:     SeverityError,
		AppVersion:   "1.0.0",
		BuildNumber:  "1",
		Platform:     "linux",
		Properties: map[string]any{
			"message": "password=server-password ssh://alice@example.test:22/home/alice command rm -rf /tmp/private",
			"details": "",
		},
		Error: &TelemetryError{
			ErrorCode:       "APP_UNCAUGHT_ERROR",
			Category:        "app",
			TerminalFailure: false,
			Message:         strings.Repeat("m", MaxDiagnosticMessageLength+100),
			StackTrace:      "Authorization: Bearer stack-secret\n" + strings.Repeat("x", MaxDiagnosticStackTraceLength+100),
		},
	}
	if _, err := service.IngestBatch(context.Background(), []TelemetryEnvelope{envelope}); err != nil {
		t.Fatalf("ingest diagnostic: %v", err)
	}
	rows, total, err := store.QueryDiagnostics(context.Background(), QueryFilter{})
	if err != nil || total != 1 {
		t.Fatalf("query diagnostic total=%d err=%v", total, err)
	}
	row := rows[0]
	for _, fragment := range []string{"server-password", "alice@example.test", "/home/alice", "rm -rf /tmp/private", "stack-secret"} {
		if strings.Contains(row.Properties["message"].(string), fragment) || strings.Contains(row.Error.Message, fragment) || strings.Contains(row.Error.StackTrace, fragment) {
			t.Fatalf("sensitive fragment %q survived server sanitization: %#v", fragment, row)
		}
	}
	if len([]byte(row.Error.Message)) > MaxDiagnosticMessageLength || len([]byte(row.Error.StackTrace)) > MaxDiagnosticStackTraceLength {
		t.Fatalf("diagnostic text exceeded server bounds: message=%d stack=%d", len([]byte(row.Error.Message)), len([]byte(row.Error.StackTrace)))
	}
}

func TestTelemetryServerRedactsDiagnosticPrivacyVariants(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	variants := []struct {
		name      string
		input     string
		sensitive string
	}{
		{name: "password assignment", input: "password=placeholder-password", sensitive: "placeholder-password"},
		{name: "quoted password assignment", input: `{"password":"placeholder-quoted-password"}`, sensitive: "placeholder-quoted-password"},
		{name: "token word", input: "token placeholder-token", sensitive: "placeholder-token"},
		{name: "credential word", input: "credential placeholder-credential", sensitive: "placeholder-credential"},
		{name: "auth word", input: "auth placeholder-auth", sensitive: "placeholder-auth"},
		{name: "user name", input: "user_name placeholder-user-name", sensitive: "placeholder-user-name"},
		{name: "authorization", input: "Authorization: Bearer placeholder-bearer", sensitive: "placeholder-bearer"},
		{name: "cookie", input: "Cookie: sid=placeholder-cookie", sensitive: "placeholder-cookie"},
		{name: "api key", input: "x-api-key: placeholder-api-key", sensitive: "placeholder-api-key"},
		{name: "basic", input: "Basic placeholder-basic", sensitive: "placeholder-basic"},
		{name: "jwt", input: "header1234.payload1234.signature1234", sensitive: "header1234.payload1234.signature1234"},
		{name: "private key", input: "-----BEGIN OPENSSH PRIVATE KEY-----\nplaceholder-key\n-----END OPENSSH PRIVATE KEY-----", sensitive: "placeholder-key"},
		{name: "known token", input: "sk-abcdefghijkl", sensitive: "sk-abcdefghijkl"},
		{name: "user at host", input: "ssh://placeholder-user@192.0.2.10:22/home/placeholder", sensitive: "placeholder-user@192.0.2.10"},
		{name: "dns and ipv6", input: "host.example.test and 2001:db8::1", sensitive: "host.example.test"},
		{name: "command and path", input: "command cat /tmp/placeholder/file", sensitive: "cat /tmp/placeholder/file"},
		{name: "windows path", input: `C:\placeholder\file`, sensitive: `C:\placeholder\file`},
		{name: "home path", input: "~/placeholder/file", sensitive: "~/placeholder/file"},
		{name: "relative path", input: `./relative/file`, sensitive: `./relative/file`},
		{name: "package path", input: "packages/placeholder/file.dart", sensitive: "packages/placeholder/file.dart"},
		{name: "secret query", input: "?access_token=placeholder-query&next=1", sensitive: "placeholder-query"},
	}
	envelopes := make([]TelemetryEnvelope, 0, len(variants))
	for i, variant := range variants {
		envelopes = append(envelopes, TelemetryEnvelope{
			EventID:      "server-privacy-variant-" + strconv.Itoa(i),
			RecordType:   RecordTypeDiagnostic,
			EventName:    "app.diagnostic.log",
			EventVersion: 1,
			DeviceID:     "privacy-variant-device",
			SessionID:    "privacy-variant-session",
			TraceID:      "privacy-variant-trace-" + strconv.Itoa(i),
			OccurredAt:   time.Now().UTC(),
			Feature:      "app",
			Severity:     SeverityWarn,
			AppVersion:   "1.0.0",
			BuildNumber:  "1",
			Platform:     "linux",
			Properties:   map[string]any{"message": variant.input},
		})
	}
	if _, err := service.IngestBatch(context.Background(), envelopes); err != nil {
		t.Fatalf("ingest privacy variants: %v", err)
	}
	rows, total, err := store.QueryDiagnostics(context.Background(), QueryFilter{})
	if err != nil || total != len(variants) {
		t.Fatalf("privacy variant total=%d err=%v, want %d", total, err, len(variants))
	}
	for i, variant := range variants {
		message, ok := rows[i].Properties["message"].(string)
		if !ok || strings.Contains(message, variant.sensitive) {
			t.Fatalf("variant %q retained sensitive text: %q", variant.name, message)
		}
	}
}
