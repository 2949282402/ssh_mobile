package admin_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	. "github.com/ssh-mobile/relay/internal/admin"
	"github.com/ssh-mobile/relay/internal/telemetry"
)

const managementClientToken = "management-client-test-token"

func TestRelayManagementClientReadsManagementResponses(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+managementClientToken {
			t.Errorf("Authorization = %q, want test bearer token", r.Header.Get("Authorization"))
		}
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == RelayInternalPathStatus:
			_, _ = w.Write([]byte(`{"server_time":123,"uptime_seconds":9,"devices":{"enrolled":2,"online":1},"relay":{"active_transfers":3},"runtime":{"allocated_mem_mb":4.5,"goroutines":7},"presence_available":true}`))
		case r.Method == http.MethodGet && r.URL.Path == RelayInternalPathDevices:
			_, _ = w.Write([]byte(`{"items":[{"device_id":"device-a","platform":"test","protocol_version":2,"online":true}],"total":1,"presence_available":true}`))
		case r.Method == http.MethodGet && r.URL.Path == RelayInternalPathToken:
			_, _ = w.Write([]byte(`{"enrollment_token":"token-a"}`))
		case r.Method == http.MethodPost && r.URL.Path == RelayInternalPathRotateToken:
			_, _ = w.Write([]byte(`{"enrollment_token":"token-b"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	client := NewRelayManagementClient(server.URL+"/", managementClientToken)
	ctx := context.Background()
	status, err := client.Status(ctx)
	if err != nil {
		t.Fatalf("Status failed: %v", err)
	}
	if status.ServerTime != 123 || status.Devices.Enrolled != 2 || status.Relay.ActiveTransfers != 3 || !status.PresenceAvailable {
		t.Fatalf("unexpected status response: %+v", status)
	}

	devices, err := client.Devices(ctx)
	if err != nil {
		t.Fatalf("Devices failed: %v", err)
	}
	if devices.Total != 1 || len(devices.Items) != 1 || devices.Items[0].DeviceID != "device-a" || !devices.PresenceAvailable {
		t.Fatalf("unexpected devices response: %+v", devices)
	}

	token, err := client.EnrollmentToken(ctx)
	if err != nil || token.EnrollmentToken != "token-a" {
		t.Fatalf("EnrollmentToken = %+v, err=%v", token, err)
	}
	rotated, err := client.RotateEnrollmentToken(ctx)
	if err != nil || rotated.EnrollmentToken != "token-b" {
		t.Fatalf("RotateEnrollmentToken = %+v, err=%v", rotated, err)
	}
}

func TestRelayManagementClientMapsHTTPStatuses(t *testing.T) {
	statuses := []struct {
		status int
		want   error
	}{
		{http.StatusNotFound, ErrDeviceNotFound},
		{http.StatusTooManyRequests, ErrResourceLimit},
		{http.StatusConflict, ErrConflict},
		{http.StatusBadGateway, ErrRelayUnavailable},
	}
	for _, tc := range statuses {
		t.Run(http.StatusText(tc.status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.status)
			}))
			defer server.Close()
			_, err := NewRelayManagementClient(server.URL, managementClientToken).Status(context.Background())
			if !errors.Is(err, tc.want) {
				t.Fatalf("Status error = %v, want %v", err, tc.want)
			}
		})
	}

	for _, tc := range statuses {
		t.Run("revoke "+http.StatusText(tc.status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.status)
			}))
			defer server.Close()
			err := NewRelayManagementClient(server.URL, managementClientToken).RevokeDevice(context.Background(), "device-a")
			if !errors.Is(err, tc.want) {
				t.Fatalf("RevokeDevice error = %v, want %v", err, tc.want)
			}
		})
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer server.Close()
	client := NewRelayManagementClient(server.URL, managementClientToken)
	if _, err := client.Devices(context.Background()); !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("Devices outage error = %v, want ErrRelayUnavailable", err)
	}
	if _, err := client.EnrollmentToken(context.Background()); !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("EnrollmentToken outage error = %v, want ErrRelayUnavailable", err)
	}
	if _, err := client.RotateEnrollmentToken(context.Background()); !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("RotateEnrollmentToken outage error = %v, want ErrRelayUnavailable", err)
	}
	if err := client.RevokeDevice(context.Background(), "device-a"); !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("RevokeDevice outage error = %v, want ErrRelayUnavailable", err)
	}
}

func TestRelayManagementClientStopsRedirectsAndValidatesAttestationResponses(t *testing.T) {
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/other", http.StatusTemporaryRedirect)
	}))
	defer redirect.Close()
	_, err := NewRelayManagementClient(redirect.URL, managementClientToken).Status(context.Background())
	if !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("redirect error = %v, want ErrRelayUnavailable", err)
	}

	for _, tc := range []struct {
		name string
		body string
		code int
		want error
	}{
		{name: "malformed success", body: "not-json", code: http.StatusOK, want: telemetry.ErrDeviceAttestorUnavailable},
		{name: "rejected proof", body: "rejected", code: http.StatusBadRequest, want: ErrRelayAttestation},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.code)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer server.Close()
			attestor, ok := NewRelayManagementClient(server.URL, managementClientToken).(telemetry.DeviceAttestor)
			if !ok {
				t.Fatal("management client does not expose attestation")
			}
			_, err := attestor.ValidateDeviceCredential(context.Background(), telemetry.DeviceAttestationRequest{DeviceID: "device-a"})
			if !errors.Is(err, tc.want) {
				t.Fatalf("ValidateDeviceCredential error = %v, want %v", err, tc.want)
			}
		})
	}
}

func TestRelayManagementClientRejectsMalformedAndUnavailableResponses(t *testing.T) {
	malformed := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte("not-json"))
	}))
	defer malformed.Close()
	client := NewRelayManagementClient(malformed.URL, managementClientToken)
	ctx := context.Background()
	if _, err := client.Status(ctx); !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("malformed Status error = %v, want ErrRelayUnavailable", err)
	}
	if _, err := client.Devices(ctx); !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("malformed Devices error = %v, want ErrRelayUnavailable", err)
	}
	if _, err := client.EnrollmentToken(ctx); !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("malformed EnrollmentToken error = %v, want ErrRelayUnavailable", err)
	}
	if _, err := client.RotateEnrollmentToken(ctx); !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("malformed RotateEnrollmentToken error = %v, want ErrRelayUnavailable", err)
	}

	unavailable := NewRelayManagementClient("http://127.0.0.1:1", managementClientToken)
	if _, err := unavailable.Status(ctx); !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("unavailable Status error = %v, want ErrRelayUnavailable", err)
	}
	if _, err := unavailable.Devices(ctx); !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("unavailable Devices error = %v, want ErrRelayUnavailable", err)
	}
	if _, err := unavailable.EnrollmentToken(ctx); !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("unavailable EnrollmentToken error = %v, want ErrRelayUnavailable", err)
	}
	if _, err := unavailable.RotateEnrollmentToken(ctx); !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("unavailable RotateEnrollmentToken error = %v, want ErrRelayUnavailable", err)
	}
	if err := unavailable.RevokeDevice(ctx, "device-a"); !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("unavailable RevokeDevice error = %v, want ErrRelayUnavailable", err)
	}
	attestor, ok := unavailable.(telemetry.DeviceAttestor)
	if !ok {
		t.Fatal("management client does not expose attestation")
	}
	if _, err := attestor.ValidateDeviceCredential(ctx, telemetry.DeviceAttestationRequest{DeviceID: "device-a"}); !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("unavailable ValidateDeviceCredential error = %v, want ErrRelayUnavailable", err)
	}
}

func TestRelayManagementClientRejectsInvalidURLs(t *testing.T) {
	client := NewRelayManagementClient("://invalid", managementClientToken)
	ctx := context.Background()
	if _, err := client.Status(ctx); err == nil {
		t.Fatal("Status accepted an invalid URL")
	}
	if _, err := client.Devices(ctx); err == nil {
		t.Fatal("Devices accepted an invalid URL")
	}
	if _, err := client.EnrollmentToken(ctx); err == nil {
		t.Fatal("EnrollmentToken accepted an invalid URL")
	}
	if _, err := client.RotateEnrollmentToken(ctx); err == nil {
		t.Fatal("RotateEnrollmentToken accepted an invalid URL")
	}
	if err := client.RevokeDevice(ctx, "device-a"); err == nil {
		t.Fatal("RevokeDevice accepted an invalid URL")
	}
}
