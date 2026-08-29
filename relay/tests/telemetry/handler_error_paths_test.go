package telemetry_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func handlerMux(handler *Handler) *http.ServeMux {
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)
	handler.RegisterAdminRoutes(mux, func(next http.HandlerFunc) http.HandlerFunc { return next })
	return mux
}

func TestTelemetryHandlersRejectUnsupportedMethods(t *testing.T) {
	mux := handlerMux(NewHandler(nil))
	cases := []struct {
		path   string
		method string
	}{
		{RoutePublicEnroll, http.MethodGet}, {RoutePublicRotate, http.MethodGet},
		{RoutePublicAuth, http.MethodGet}, {RoutePublicIngest, http.MethodGet},
		{RoutePublicPolicy, http.MethodPost},
		{PathAdminOverview, http.MethodPost}, {PathAdminEvents, http.MethodPost},
		{PathAdminDiagnostics, http.MethodPost}, {PathAdminSettings, http.MethodPatch},
	}
	for _, tc := range cases {
		t.Run(tc.method+tc.path, func(t *testing.T) {
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, httptest.NewRequest(tc.method, tc.path, nil))
			if rec.Code != http.StatusMethodNotAllowed {
				t.Fatalf("%s %s status = %d, want 405", tc.method, tc.path, rec.Code)
			}
		})
	}
}

func TestTelemetryHandlersRejectUnavailableServices(t *testing.T) {
	mux := handlerMux(NewHandler(nil))
	cases := []struct {
		name   string
		path   string
		method string
	}{
		{"enroll", RoutePublicEnroll, http.MethodPost}, {"rotate", RoutePublicRotate, http.MethodPost},
		{"auth", RoutePublicAuth, http.MethodPost}, {"ingest", RoutePublicIngest, http.MethodPost},
		{"policy", RoutePublicPolicy, http.MethodGet},
		{"overview", PathAdminOverview, http.MethodGet}, {"events", PathAdminEvents, http.MethodGet},
		{"diagnostics", PathAdminDiagnostics, http.MethodGet}, {"settings get", PathAdminSettings, http.MethodGet},
		{"settings put", PathAdminSettings, http.MethodPut},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, httptest.NewRequest(tc.method, tc.path, nil))
			if rec.Code != http.StatusServiceUnavailable {
				t.Fatalf("%s status = %d, want 503: %s", tc.name, rec.Code, rec.Body.String())
			}
		})
	}
}

func TestPublicCredentialAndAuthHandlersRejectMalformedRequests(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	attestor := &testDeviceAttestor{result: DeviceAttestation{DeviceID: "handler-device"}}
	mux := handlerMux(NewHandler(service, attestor))

	malformed := httptest.NewRecorder()
	mux.ServeHTTP(malformed, httptest.NewRequest(http.MethodPost, RoutePublicEnroll, strings.NewReader("{")))
	if malformed.Code != http.StatusBadRequest {
		t.Fatalf("malformed enrollment status = %d, want 400", malformed.Code)
	}
	badDevice := httptest.NewRecorder()
	mux.ServeHTTP(badDevice, httptest.NewRequest(http.MethodPost, RoutePublicEnroll, strings.NewReader(`{"deviceId":"bad:device"}`)))
	if badDevice.Code != http.StatusBadRequest {
		t.Fatalf("invalid enrollment device status = %d, want 400", badDevice.Code)
	}

	enrollment := TelemetryEnrollmentRequest{
		DeviceID: "handler-device", RelayCredential: "relay", PublicKey: "key",
		Timestamp: 1, Nonce: "nonce", Signature: "signature",
	}
	enrollmentJSON, _ := json.Marshal(enrollment)
	rotated := httptest.NewRecorder()
	mux.ServeHTTP(rotated, httptest.NewRequest(http.MethodPost, RoutePublicRotate, strings.NewReader(string(enrollmentJSON))))
	if rotated.Code != http.StatusNotFound || !strings.Contains(rotated.Body.String(), "NOT_ENROLLED") {
		t.Fatalf("unregistered rotation = %d %s, want 404 NOT_ENROLLED", rotated.Code, rotated.Body.String())
	}

	authMalformed := httptest.NewRecorder()
	mux.ServeHTTP(authMalformed, httptest.NewRequest(http.MethodPost, RoutePublicAuth, strings.NewReader("{")))
	if authMalformed.Code != http.StatusBadRequest {
		t.Fatalf("malformed auth status = %d, want 400", authMalformed.Code)
	}
	authInvalid := httptest.NewRecorder()
	mux.ServeHTTP(authInvalid, httptest.NewRequest(http.MethodPost, RoutePublicAuth, strings.NewReader(`{"deviceId":"bad:device","proof":"bad","expEpoch":1}`)))
	if authInvalid.Code != http.StatusBadRequest {
		t.Fatalf("invalid auth device status = %d, want 400", authInvalid.Code)
	}

	_, hash := registerDevice(t, store, "handler-auth-device")
	authBody := fmt.Sprintf(`{"deviceId":"handler-auth-device","proof":"wrong","expEpoch":%d}`, futureEpoch())
	wrongProof := httptest.NewRecorder()
	mux.ServeHTTP(wrongProof, httptest.NewRequest(http.MethodPost, RoutePublicAuth, strings.NewReader(authBody)))
	if wrongProof.Code != http.StatusUnauthorized || !strings.Contains(wrongProof.Body.String(), "AUTH_FAILED") {
		t.Fatalf("wrong auth proof = %d %s, want 401 AUTH_FAILED", wrongProof.Code, wrongProof.Body.String())
	}
	_ = hash

	credentialFailure := &handlerErrorStore{MemoryStore: NewMemoryStore(DefaultCatalog()), credentialErr: errors.New("credential lookup failed")}
	failureHandler := handlerMux(NewHandler(NewServiceWithSecret(credentialFailure, DefaultCatalog(), &NoopRedisCache{}, testAuthSecret)))
	credentialBody := fmt.Sprintf(`{"deviceId":"handler-credential-failure","proof":"bad","expEpoch":%d}`, futureEpoch())
	failure := httptest.NewRecorder()
	failureHandler.ServeHTTP(failure, httptest.NewRequest(http.MethodPost, RoutePublicAuth, strings.NewReader(credentialBody)))
	if failure.Code != http.StatusServiceUnavailable {
		t.Fatalf("credential lookup failure = %d, want 503", failure.Code)
	}
}

func TestPublicIngestHandlerRejectsBoundedPayloadsAndAllowsEmptyBatch(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	deviceID := "handler-ingest-device"
	token := mustAuth(t, service, store, deviceID)
	handler := NewHandlerWithConfig(service, IngestConfig{MaxBodyBytes: 10}, nil)
	smallMux := handlerMux(handler)

	oversized := httptest.NewRequest(http.MethodPost, RoutePublicIngest, strings.NewReader(`{"records":[]}`))
	oversized.ContentLength = -1
	oversized.Header.Set("Authorization", "Bearer "+token)
	oversized.Header.Set("X-Device-Id", deviceID)
	oversizedRec := httptest.NewRecorder()
	smallMux.ServeHTTP(oversizedRec, oversized)
	if oversizedRec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("streaming oversized ingest = %d, want 413: %s", oversizedRec.Code, oversizedRec.Body.String())
	}
	mux := handlerMux(NewHandler(service))

	invalid := httptest.NewRequest(http.MethodPost, RoutePublicIngest, strings.NewReader("not-json"))
	invalid.Header.Set("Authorization", "Bearer "+token)
	invalid.Header.Set("X-Device-Id", deviceID)
	invalidRec := httptest.NewRecorder()
	mux.ServeHTTP(invalidRec, invalid)
	if invalidRec.Code != http.StatusBadRequest {
		t.Fatalf("invalid ingest JSON = %d, want 400", invalidRec.Code)
	}

	trailing := httptest.NewRequest(http.MethodPost, RoutePublicIngest, strings.NewReader(`{"records":[]} trailing`))
	trailing.Header.Set("Authorization", "Bearer "+token)
	trailing.Header.Set("X-Device-Id", deviceID)
	trailingRec := httptest.NewRecorder()
	mux.ServeHTTP(trailingRec, trailing)
	if trailingRec.Code != http.StatusBadRequest {
		t.Fatalf("trailing ingest data = %d, want 400", trailingRec.Code)
	}

	empty := httptest.NewRequest(http.MethodPost, RoutePublicIngest, strings.NewReader(`{"records":[]}`))
	empty.Header.Set("Authorization", "Bearer "+token)
	empty.Header.Set("X-Device-Id", deviceID)
	emptyRec := httptest.NewRecorder()
	mux.ServeHTTP(emptyRec, empty)
	if emptyRec.Code != http.StatusOK || !strings.Contains(emptyRec.Body.String(), `"results":[]`) {
		t.Fatalf("empty ingest = %d %s, want empty success", emptyRec.Code, emptyRec.Body.String())
	}
}

func TestPublicIngestRetryAfterHonorsConfiguredCeiling(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	deviceID := "handler-retry-ceiling"
	token := mustAuth(t, service, store, deviceID)
	now := time.Unix(900, 0).UTC()
	handler := NewHandlerWithConfig(service, IngestConfig{
		RateLimitCapacity: 1, RateLimitRefillPerSecond: 0.8, RetryAfterSeconds: 1,
		Clock: func() time.Time { return now },
	}, nil)
	mux := handlerMux(handler)
	request := func(eventID string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, RoutePublicIngest, strings.NewReader(fmt.Sprintf(`{"records":[{"eventId":"%s"}]}`, eventID)))
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("X-Device-Id", deviceID)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		return rec
	}
	if first := request("handler-retry-first"); first.Code != http.StatusOK {
		t.Fatalf("first retry-ceiling request = %d: %s", first.Code, first.Body.String())
	}
	limited := request("handler-retry-second")
	if limited.Code != http.StatusTooManyRequests || limited.Header().Get("Retry-After") != "1" {
		t.Fatalf("retry-ceiling response = %d Retry-After=%q, want 429/1", limited.Code, limited.Header().Get("Retry-After"))
	}
}

func TestAdminHandlersReportStoreFailuresAndNormalizeFilters(t *testing.T) {
	failing := &failingIngestStore{}
	failureMux := handlerMux(NewHandler(NewServiceWithSecret(failing, DefaultCatalog(), &NoopRedisCache{}, testAuthSecret)))
	for _, tc := range []struct {
		name string
		path string
		body string
	}{
		{"policy", PathPublicPolicy, ""},
		{"overview", PathAdminOverview, ""},
		{"events", PathAdminEvents, ""},
		{"diagnostics", PathAdminDiagnostics, ""},
		{"settings get", PathAdminSettings, ""},
		{"settings put", PathAdminSettings, `{"retentionDays":30}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			method := http.MethodGet
			if tc.name == "settings put" {
				method = http.MethodPut
			}
			rec := httptest.NewRecorder()
			failureMux.ServeHTTP(rec, httptest.NewRequest(method, tc.path, strings.NewReader(tc.body)))
			if rec.Code != http.StatusInternalServerError {
				t.Fatalf("%s error status = %d, want 500: %s", tc.name, rec.Code, rec.Body.String())
			}
		})
	}

	store := NewMemoryStore(DefaultCatalog())
	mux := handlerMux(NewHandler(NewServiceWithSecret(store, DefaultCatalog(), &NoopRedisCache{}, testAuthSecret)))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, PathAdminEvents+"?startTime=bad&endTime=bad&page=bad&pageSize=999", nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"page":1`) || !strings.Contains(rec.Body.String(), `"pageSize":50`) {
		t.Fatalf("normalized admin event filter = %d %s", rec.Code, rec.Body.String())
	}
}

type handlerErrorStore struct {
	*MemoryStore
	credentialErr error
}

func (s *handlerErrorStore) GetDeviceCredential(context.Context, string) (string, error) {
	return "", s.credentialErr
}
