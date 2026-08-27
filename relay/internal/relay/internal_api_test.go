package relay

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func newTestInternalAPIServer(t *testing.T) (*Server, *http.ServeMux, string) {
	t.Helper()
	internalToken := "0123456789abcdef0123456789abcdef"
	server := NewServer(Config{
		CredentialKey:   []byte("01234567890123456789012345678901"),
		EnrollmentToken: "test-enrollment-token",
		InternalToken:   internalToken,
		CredentialTTL:   time.Hour,
	})
	t.Cleanup(server.Close)

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	return server, mux, internalToken
}

func TestInternalAPIAuthentication(t *testing.T) {
	_, mux, validToken := newTestInternalAPIServer(t)

	endpoints := []struct {
		method string
		path   string
	}{
		{http.MethodGet, PathInternalStatusV2},
		{http.MethodGet, PathInternalDevicesV2},
		{http.MethodPost, PathInternalRevokeDeviceV2 + "dev-1/revoke"},
		{http.MethodGet, PathInternalTokenV2},
		{http.MethodPost, PathInternalRotateTokenV2},
		{http.MethodPost, PathInternalTelemetryAttest},
	}

	for _, ep := range endpoints {
		t.Run(ep.method+" "+ep.path, func(t *testing.T) {
			// 1. Missing Token -> 401
			req := httptest.NewRequest(ep.method, ep.path, nil)
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("missing auth token status = %d, want 401", rec.Code)
			}

			// 2. Wrong Token -> 401
			req = httptest.NewRequest(ep.method, ep.path, nil)
			req.Header.Set("Authorization", "Bearer wrong-internal-token")
			rec = httptest.NewRecorder()
			mux.ServeHTTP(rec, req)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("wrong auth token status = %d, want 401", rec.Code)
			}

			// 3. Valid Token -> should not be 401
			req = httptest.NewRequest(ep.method, ep.path, nil)
			req.Header.Set("Authorization", "Bearer "+validToken)
			rec = httptest.NewRecorder()
			mux.ServeHTTP(rec, req)
			if rec.Code == http.StatusUnauthorized {
				t.Fatalf("valid auth token received 401")
			}
		})
	}
}

func TestInternalAPIStatusAndDevices(t *testing.T) {
	server, mux, token := newTestInternalAPIServer(t)

	pubKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encodedKey := base64.RawURLEncoding.EncodeToString(pubKey)
	if result := server.replaceEnrollment("internal-test-dev", encodedKey, "linux", RelayBootstrapProtocolVersion, time.Now()); result != enrollmentOK {
		t.Fatalf("replaceEnrollment: %v", result)
	}

	// 1. GET /internal/v2/status
	req := httptest.NewRequest(http.MethodGet, PathInternalStatusV2, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status code = %d, want 200. Body: %s", rec.Code, rec.Body.String())
	}
	var statusResp internalStatusResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &statusResp); err != nil {
		t.Fatalf("decode status response: %v", err)
	}
	if statusResp.Devices.Enrolled != 1 {
		t.Fatalf("enrolled devices = %d, want 1", statusResp.Devices.Enrolled)
	}

	// 2. GET /internal/v2/devices
	req = httptest.NewRequest(http.MethodGet, PathInternalDevicesV2, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("devices code = %d, want 200. Body: %s", rec.Code, rec.Body.String())
	}
	var devicesResp internalDevicesResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &devicesResp); err != nil {
		t.Fatalf("decode devices response: %v", err)
	}
	if devicesResp.Total != 1 || len(devicesResp.Items) != 1 || devicesResp.Items[0].DeviceID != "internal-test-dev" {
		t.Fatalf("unexpected devices response: %+v", devicesResp)
	}
}

func TestInternalAPIRevokeDevice(t *testing.T) {
	server, mux, token := newTestInternalAPIServer(t)

	pubKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encodedKey := base64.RawURLEncoding.EncodeToString(pubKey)
	if result := server.replaceEnrollment("revoke-me", encodedKey, "linux", RelayBootstrapProtocolVersion, time.Now()); result != enrollmentOK {
		t.Fatalf("replaceEnrollment: %v", result)
	}

	// Revoke existing device -> 204
	req := httptest.NewRequest(http.MethodPost, PathInternalRevokeDeviceV2+"revoke-me/revoke", nil)
	req.SetPathValue("deviceId", "revoke-me")
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("revoke status = %d, want 204. Body: %s", rec.Code, rec.Body.String())
	}

	// Revoke non-existing device -> 404
	req = httptest.NewRequest(http.MethodPost, PathInternalRevokeDeviceV2+"revoke-me/revoke", nil)
	req.SetPathValue("deviceId", "revoke-me")
	req.Header.Set("Authorization", "Bearer "+token)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("revoke non-existing status = %d, want 404", rec.Code)
	}
}

func TestInternalAPITokenAndRotate(t *testing.T) {
	_, mux, token := newTestInternalAPIServer(t)

	// 1. GET /internal/v2/access/enrollment-token
	req := httptest.NewRequest(http.MethodGet, PathInternalTokenV2, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("token status = %d, want 200", rec.Code)
	}
	var tokenResp map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &tokenResp); err != nil || tokenResp["enrollment_token"] != "test-enrollment-token" {
		t.Fatalf("unexpected token response: %+v", tokenResp)
	}

	// 2. POST /internal/v2/access/enrollment-token/rotate
	req = httptest.NewRequest(http.MethodPost, PathInternalRotateTokenV2, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("rotate status = %d, want 200", rec.Code)
	}
	var rotateResp map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &rotateResp); err != nil || rotateResp["enrollment_token"] == "" || rotateResp["enrollment_token"] == "test-enrollment-token" {
		t.Fatalf("unexpected rotate response: %+v", rotateResp)
	}
}
