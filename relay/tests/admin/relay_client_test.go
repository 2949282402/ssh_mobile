package admin_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/admin"
	"github.com/ssh-mobile/relay/internal/telemetry"
)

func TestRelayManagementClientRevokeDeviceEscapesPath(t *testing.T) {
	testCases := []struct {
		name         string
		deviceID     string
		expectedPath string
	}{
		{
			name:         "standard device ID",
			deviceID:     "device-123",
			expectedPath: RelayInternalPathRevokePrefix + "device-123/revoke",
		},
		{
			name:         "device ID with forward slash",
			deviceID:     "dev/ice/sub-456",
			expectedPath: RelayInternalPathRevokePrefix + "dev%2Fice%2Fsub-456/revoke",
		},
		{
			name:         "device ID with percent sign",
			deviceID:     "dev%20_test",
			expectedPath: RelayInternalPathRevokePrefix + "dev%2520_test/revoke",
		},
		{
			name:         "device ID with spaces",
			deviceID:     "my test device",
			expectedPath: RelayInternalPathRevokePrefix + "my%20test%20device/revoke",
		},
		{
			name:         "device ID with unicode characters",
			deviceID:     "设备-device-🚀",
			expectedPath: RelayInternalPathRevokePrefix + url.PathEscape("设备-device-🚀") + "/revoke",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			var recordedPath string
			var recordedAuth string

			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				recordedPath = r.URL.EscapedPath()
				recordedAuth = r.Header.Get("Authorization")
				w.WriteHeader(http.StatusNoContent)
			}))
			defer server.Close()

			client := NewRelayManagementClient(server.URL, "test-secret-token")

			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()

			err := client.RevokeDevice(ctx, tc.deviceID)
			if err != nil {
				t.Fatalf("RevokeDevice failed: %v", err)
			}

			if recordedPath != tc.expectedPath {
				t.Errorf("path = %q, want %q", recordedPath, tc.expectedPath)
			}

			if recordedAuth != "Bearer test-secret-token" {
				t.Errorf("Authorization = %q, want %q", recordedAuth, "Bearer test-secret-token")
			}
		})
	}
}

func TestAdminRevokeDeviceSpecialCharactersForwarding(t *testing.T) {
	specialIDs := []string{
		"device-123",
		"device/sub-id",
		"dev%20_special",
		"my device with space",
		"设备-01-测试",
	}

	for _, devID := range specialIDs {
		t.Run(devID, func(t *testing.T) {
			var relayReceivedPath string
			relayBackend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				relayReceivedPath = r.URL.EscapedPath()
				w.WriteHeader(http.StatusNoContent)
			}))
			defer relayBackend.Close()

			adminSvc := NewServerWithClient(Config{
				Address:       ":8081",
				AdminUser:     "admin",
				AdminPassword: "password-123456",
				AuthKey:       []byte("12345678901234567890123456789012"),
			}, NewRelayManagementClient(relayBackend.URL, "token"))
			defer adminSvc.Close()

			mux := http.NewServeMux()
			adminSvc.RegisterRoutes(mux)

			escapedID := url.PathEscape(devID)
			loginBody, err := json.Marshal(map[string]string{
				"username": "admin",
				"password": "password-123456",
			})
			if err != nil {
				t.Fatalf("marshal admin login: %v", err)
			}
			loginReq := httptest.NewRequest(http.MethodPost, PathAuthLogin, bytes.NewReader(loginBody))
			loginReq.Header.Set("Content-Type", "application/json")
			loginRec := httptest.NewRecorder()
			mux.ServeHTTP(loginRec, loginReq)
			if loginRec.Code != http.StatusOK {
				t.Fatalf("admin login status = %d, want 200: %s", loginRec.Code, loginRec.Body.String())
			}
			cookies := loginRec.Result().Cookies()
			if len(cookies) == 0 || cookies[0].Value == "" {
				t.Fatal("admin login did not return a session cookie")
			}

			req := httptest.NewRequest(http.MethodPost, PathRevokeDevice+escapedID+"/revoke", nil)
			req.AddCookie(cookies[0])

			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)

			if rec.Code != http.StatusNoContent {
				t.Fatalf("status = %d, want 204; body: %s", rec.Code, rec.Body.String())
			}

			expectedRelayPath := RelayInternalPathRevokePrefix + escapedID + "/revoke"
			if relayReceivedPath != expectedRelayPath {
				t.Errorf("relay path = %q, want %q", relayReceivedPath, expectedRelayPath)
			}
		})
	}
}

func TestRelayManagementClientValidatesDeviceCredential(t *testing.T) {
	var received telemetry.DeviceAttestationRequest
	var receivedAuth string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != RelayInternalPathTelemetryAttest {
			t.Fatalf("path = %q, want %q", r.URL.Path, RelayInternalPathTelemetryAttest)
		}
		receivedAuth = r.Header.Get("Authorization")
		var body struct {
			DeviceID        string `json:"device_id"`
			RelayCredential string `json:"relay_credential"`
			PublicKey       string `json:"public_key"`
			Timestamp       int64  `json:"timestamp"`
			Nonce           string `json:"nonce"`
			Signature       string `json:"signature"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode attestation request: %v", err)
		}
		received = telemetry.DeviceAttestationRequest{
			DeviceID:        body.DeviceID,
			RelayCredential: body.RelayCredential,
			PublicKey:       body.PublicKey,
			Timestamp:       body.Timestamp,
			Nonce:           body.Nonce,
			Signature:       body.Signature,
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"device_id":             "device-a",
			"enrollment_generation": int64(42),
			"protocol_version":      uint32(2),
		})
	}))
	defer server.Close()

	client := NewRelayManagementClient(server.URL, "internal-token")
	attestor, ok := client.(telemetry.DeviceAttestor)
	if !ok {
		t.Fatal("RelayManagementClient must expose the telemetry attestation capability")
	}
	got, err := attestor.ValidateDeviceCredential(context.Background(), telemetry.DeviceAttestationRequest{
		DeviceID:        "device-a",
		RelayCredential: "credential",
		PublicKey:       "public-key",
		Timestamp:       123,
		Nonce:           "nonce",
		Signature:       "signature",
	})
	if err != nil {
		t.Fatalf("ValidateDeviceCredential failed: %v", err)
	}
	if got.DeviceID != "device-a" || got.EnrollmentGeneration != 42 || got.ProtocolVersion != 2 {
		t.Fatalf("unexpected attestation: %+v", got)
	}
	if receivedAuth != "Bearer internal-token" {
		t.Fatalf("Authorization = %q, want Bearer internal-token", receivedAuth)
	}
	if received.DeviceID != "device-a" || received.RelayCredential != "credential" || received.PublicKey != "public-key" || received.Timestamp != 123 || received.Nonce != "nonce" || received.Signature != "signature" {
		t.Fatalf("unexpected forwarded attestation request: %+v", received)
	}
}

func TestRelayManagementClientMapsAttestationOutageWithoutEchoingProof(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer server.Close()
	client, ok := NewRelayManagementClient(server.URL, "internal-token").(telemetry.DeviceAttestor)
	if !ok {
		t.Fatal("RelayManagementClient must expose the telemetry attestation capability")
	}
	_, err := client.ValidateDeviceCredential(context.Background(), telemetry.DeviceAttestationRequest{
		DeviceID:        "device-a",
		RelayCredential: "private-proof-material",
	})
	if !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("error = %v, want ErrRelayUnavailable", err)
	}
	if strings.Contains(err.Error(), "private-proof-material") {
		t.Fatal("attestation error echoed proof material")
	}
}
