package relay_test

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestInternalAPIAuthentication(t *testing.T) {
	_, mux := newRelayTestServer(t)

	endpoints := []struct {
		method string
		path   string
	}{
		{http.MethodGet, "/internal/v2/status"},
		{http.MethodGet, "/internal/v2/devices"},
		{http.MethodPost, "/internal/v2/devices/dev-1/revoke"},
		{http.MethodGet, "/internal/v2/access/enrollment-token"},
		{http.MethodPost, "/internal/v2/access/enrollment-token/rotate"},
		{http.MethodPost, "/internal/v2/telemetry/attest"},
	}
	for _, endpoint := range endpoints {
		t.Run(endpoint.method+" "+endpoint.path, func(t *testing.T) {
			req := httptest.NewRequest(endpoint.method, endpoint.path, nil)
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("missing auth token status = %d, want 401", rec.Code)
			}

			req = httptest.NewRequest(endpoint.method, endpoint.path, nil)
			req.Header.Set("Authorization", "Bearer wrong-internal-token")
			rec = httptest.NewRecorder()
			mux.ServeHTTP(rec, req)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("wrong auth token status = %d, want 401", rec.Code)
			}

			req = httptest.NewRequest(endpoint.method, endpoint.path, nil)
			req.Header.Set("Authorization", "Bearer "+testInternalToken)
			rec = httptest.NewRecorder()
			mux.ServeHTTP(rec, req)
			if rec.Code == http.StatusUnauthorized {
				t.Fatalf("valid auth token received 401")
			}
		})
	}
}

func TestInternalAPIStatusAndDevices(t *testing.T) {
	_, mux := newRelayTestServer(t)
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	enrollRelayDevice(t, mux, "internal-test-dev", publicKey)

	req := httptest.NewRequest(http.MethodGet, "/internal/v2/status", nil)
	req.Header.Set("Authorization", "Bearer "+testInternalToken)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status code = %d, want 200. Body: %s", rec.Code, rec.Body.String())
	}
	var statusResp struct {
		Devices struct {
			Enrolled int `json:"enrolled"`
		} `json:"devices"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &statusResp); err != nil {
		t.Fatalf("decode status response: %v", err)
	}
	if statusResp.Devices.Enrolled != 1 {
		t.Fatalf("enrolled devices = %d, want 1", statusResp.Devices.Enrolled)
	}

	req = httptest.NewRequest(http.MethodGet, "/internal/v2/devices", nil)
	req.Header.Set("Authorization", "Bearer "+testInternalToken)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("devices code = %d, want 200. Body: %s", rec.Code, rec.Body.String())
	}
	var devicesResp struct {
		Items []struct {
			DeviceID string `json:"device_id"`
		} `json:"items"`
		Total int `json:"total"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &devicesResp); err != nil {
		t.Fatalf("decode devices response: %v", err)
	}
	if devicesResp.Total != 1 || len(devicesResp.Items) != 1 || devicesResp.Items[0].DeviceID != "internal-test-dev" {
		t.Fatalf("unexpected devices response: %+v", devicesResp)
	}
}

func TestInternalAPIRevokeDevice(t *testing.T) {
	_, mux := newRelayTestServer(t)
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	enrollRelayDevice(t, mux, "revoke-me", publicKey)

	req := httptest.NewRequest(http.MethodPost, "/internal/v2/devices/revoke-me/revoke", nil)
	req.Header.Set("Authorization", "Bearer "+testInternalToken)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("revoke status = %d, want 204. Body: %s", rec.Code, rec.Body.String())
	}

	req = httptest.NewRequest(http.MethodPost, "/internal/v2/devices/revoke-me/revoke", nil)
	req.Header.Set("Authorization", "Bearer "+testInternalToken)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("revoke non-existing status = %d, want 404", rec.Code)
	}
}

func TestInternalAPITokenAndRotate(t *testing.T) {
	_, mux := newRelayTestServer(t)

	req := httptest.NewRequest(http.MethodGet, "/internal/v2/access/enrollment-token", nil)
	req.Header.Set("Authorization", "Bearer "+testInternalToken)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("token status = %d, want 200", rec.Code)
	}
	var tokenResp map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &tokenResp); err != nil || tokenResp["enrollment_token"] != testEnrollmentToken {
		t.Fatalf("unexpected token response: %+v", tokenResp)
	}

	req = httptest.NewRequest(http.MethodPost, "/internal/v2/access/enrollment-token/rotate", nil)
	req.Header.Set("Authorization", "Bearer "+testInternalToken)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("rotate status = %d, want 200", rec.Code)
	}
	var rotateResp map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &rotateResp); err != nil || rotateResp["enrollment_token"] == "" || rotateResp["enrollment_token"] == testEnrollmentToken {
		t.Fatalf("unexpected rotate response: %+v", rotateResp)
	}
}
