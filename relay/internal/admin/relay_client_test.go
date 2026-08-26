package admin

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"
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

			// Create authenticated session
			testToken := "test-admin-session-token-12345"
			if err := adminSvc.sessionStore.Create(context.Background(), testToken, 1*time.Hour); err != nil {
				t.Fatalf("failed to create session: %v", err)
			}

			escapedID := url.PathEscape(devID)
			req := httptest.NewRequest(http.MethodPost, PathRevokeDevice+escapedID+"/revoke", nil)
			req.AddCookie(&http.Cookie{
				Name:  sessionCookieName,
				Value: testToken,
			})

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
