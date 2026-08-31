package admin_test

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/admin"
	telemetrypkg "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestTelemetryEnrollmentUsesRelayAttestationCapabilityEndToEnd(t *testing.T) {
	const (
		internalToken  = "0123456789abcdef0123456789abcdef"
		testAuthSecret = "test-telemetry-auth-secret-0123456789"
	)

	var forwarded telemetrypkg.DeviceAttestationRequest
	relayHTTP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != RelayInternalPathTelemetryAttest {
			t.Fatalf("path = %q, want %q", r.URL.Path, RelayInternalPathTelemetryAttest)
		}
		if r.Header.Get("Authorization") != "Bearer "+internalToken {
			t.Fatalf("missing Relay internal authorization")
		}
		var body struct {
			DeviceID        string `json:"device_id"`
			RelayCredential string `json:"relay_credential"`
			PublicKey       string `json:"public_key"`
			Timestamp       int64  `json:"timestamp"`
			Nonce           string `json:"nonce"`
			Signature       string `json:"signature"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode Relay attestation request: %v", err)
		}
		forwarded = telemetrypkg.DeviceAttestationRequest{
			DeviceID:        body.DeviceID,
			RelayCredential: body.RelayCredential,
			PublicKey:       body.PublicKey,
			Timestamp:       body.Timestamp,
			Nonce:           body.Nonce,
			Signature:       body.Signature,
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"device_id":             body.DeviceID,
			"enrollment_generation": int64(42),
			"protocol_version":      uint32(2),
		})
	}))
	defer relayHTTP.Close()

	telemetryStore := telemetrypkg.NewMemoryStore(telemetrypkg.DefaultCatalog())
	telemetryService := telemetrypkg.NewServiceWithSecret(
		telemetryStore,
		telemetrypkg.DefaultCatalog(),
		&telemetrypkg.NoopRedisCache{},
		testAuthSecret,
	)
	adminServer := NewServerWithClientAndTelemetry(
		Config{
			Address:            ":0",
			AdminUser:          "admin",
			AdminPassword:      "password-over-12-chars",
			AuthKey:            []byte("01234567890123456789012345678901"),
			RelayInternalToken: internalToken,
		},
		NewRelayManagementClient(relayHTTP.URL, internalToken),
		telemetryService,
	)
	defer adminServer.Close()
	adminMux := http.NewServeMux()
	adminServer.RegisterRoutes(adminMux)
	adminHTTP := httptest.NewServer(adminMux)
	defer adminHTTP.Close()

	timestamp := time.Now().Unix()
	requestBody, err := json.Marshal(telemetrypkg.TelemetryEnrollmentRequest{
		DeviceID:        "device-e2e",
		RelayCredential: "relay-credential",
		PublicKey:       "public-key",
		Timestamp:       timestamp,
		Nonce:           "nonce",
		Signature:       "signature",
	})
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(http.MethodPost, adminHTTP.URL+telemetrypkg.PathPublicEnroll, bytes.NewReader(requestBody))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusCreated {
		t.Fatalf("telemetry enrollment status=%d body=%s", response.StatusCode, responseBody(response))
	}
	var enrollment telemetrypkg.TelemetryEnrollmentResponse
	if err := json.NewDecoder(response.Body).Decode(&enrollment); err != nil {
		t.Fatal(err)
	}
	if enrollment.DeviceID != "device-e2e" || len(enrollment.Secret) != 64 {
		t.Fatalf("unexpected telemetry enrollment response: %+v", enrollment)
	}
	if forwarded.DeviceID != "device-e2e" || forwarded.RelayCredential != "relay-credential" || forwarded.PublicKey != "public-key" || forwarded.Timestamp != timestamp || forwarded.Nonce != "nonce" || forwarded.Signature != "signature" {
		t.Fatalf("Relay did not receive the bound proof request: %+v", forwarded)
	}

	storedHash, err := telemetryStore.GetDeviceCredential(t.Context(), "device-e2e")
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256([]byte(enrollment.Secret))
	if storedHash != hex.EncodeToString(digest[:]) || storedHash == enrollment.Secret {
		t.Fatal("Analytics store did not retain only the derived telemetry secret hash")
	}

	exp := time.Now().Add(time.Minute).Unix()
	proof := hmacProof("device-e2e", storedHash, exp)
	if _, _, err := telemetryService.AuthenticateDevice(t.Context(), "device-e2e", proof, exp); err != nil {
		t.Fatalf("generated telemetry secret did not preserve HMAC auth compatibility: %v", err)
	}
}

func hmacProof(deviceID, storedHash string, exp int64) string {
	mac := hmac.New(sha256.New, []byte(storedHash))
	_, _ = mac.Write([]byte("telemetry:auth:" + deviceID + ":" + strconv.FormatInt(exp, 10)))
	return hex.EncodeToString(mac.Sum(nil))
}

func responseBody(response *http.Response) string {
	var value any
	if err := json.NewDecoder(response.Body).Decode(&value); err != nil {
		return "<unavailable>"
	}
	return "<redacted>"
}
