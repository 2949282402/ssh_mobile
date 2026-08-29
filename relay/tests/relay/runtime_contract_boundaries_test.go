package relay_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/ssh-mobile/relay/internal/relay"
	"github.com/ssh-mobile/relay/internal/relay/v2"
)

func TestRelayHealthAndStartupValidation(t *testing.T) {
	server, mux := newRelayTestServer(t)
	response := serveRelayRequest(mux, "GET", relay.PathHealthz, nil)
	if response.Code != 204 || response.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("health response = %d/cache %q, want 204/no-store", response.Code, response.Header().Get("Cache-Control"))
	}
	server.Close()

	if opened, err := relay.OpenServer(relay.Config{StorageMode: "memory"}); err != nil {
		t.Fatalf("memory OpenServer failed: %v", err)
	} else {
		opened.Close()
	}
	for _, config := range []relay.Config{
		{StorageMode: "unsupported"},
		{StorageMode: "mysql"},
		{StorageMode: "mysql", DatabaseURL: "mysql-dsn"},
	} {
		if _, err := relay.OpenServer(config); err == nil {
			t.Fatalf("OpenServer(%+v) unexpectedly succeeded", config)
		}
	}
}

func TestRelaySeedEnrollmentsValidatesAndPreservesIdentityConflicts(t *testing.T) {
	server, _ := newRelayTestServer(t)
	device := relay.EnrolledDevice{
		DeviceID:        "seed-device",
		PublicKey:       "seed-public-key",
		Platform:        "test",
		ProtocolVersion: relay.RelayBootstrapProtocolVersion,
		EnrolledAt:      time.Now(),
	}
	if err := server.SeedEnrollments(context.Background(), []relay.EnrolledDevice{device}); err != nil {
		t.Fatalf("initial seed failed: %v", err)
	}
	if err := server.SeedEnrollments(context.Background(), []relay.EnrolledDevice{device}); err != nil {
		t.Fatalf("idempotent seed failed: %v", err)
	}
	conflict := device
	conflict.PublicKey = "different-public-key"
	if err := server.SeedEnrollments(context.Background(), []relay.EnrolledDevice{conflict}); err != nil {
		t.Fatalf("identity conflict should be skipped: %v", err)
	}
	unsupported := device
	unsupported.ProtocolVersion++
	if err := server.SeedEnrollments(context.Background(), []relay.EnrolledDevice{unsupported}); err == nil {
		t.Fatal("seed accepted an unsupported protocol version")
	}
}

func serveRelayRequest(mux *http.ServeMux, method, path string, body io.Reader) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, path, body)
	response := httptest.NewRecorder()
	mux.ServeHTTP(response, request)
	return response
}

func TestRelayV2CodecRejectsMalformedFrames(t *testing.T) {
	control := &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayFrame_Heartbeat{Heartbeat: &v2.Heartbeat{RequestId: 7}},
	}
	encoded, err := v2.EncodeFrame(control)
	if err != nil {
		t.Fatalf("EncodeFrame failed: %v", err)
	}
	decoded, err := v2.DecodeControl(encoded)
	if err != nil || decoded.GetHeartbeat().GetRequestId() != 7 {
		t.Fatalf("control round trip = %+v, err=%v", decoded, err)
	}
	if _, err := v2.EncodeFrame(nil); err == nil {
		t.Fatal("EncodeFrame accepted nil")
	}
	if _, err := v2.EncodeDataFrame(nil); err == nil {
		t.Fatal("EncodeDataFrame accepted nil")
	}

	for _, tc := range []struct {
		name string
		data []byte
		want error
	}{
		{name: "short prefix", data: []byte{1, 2}, want: v2.ErrFrameTooShort},
		{name: "length mismatch", data: []byte{0, 0, 0, 2, 1}, want: v2.ErrLengthMismatch},
		{name: "malformed protobuf", data: func() []byte {
			value := make([]byte, 5)
			binary.BigEndian.PutUint32(value, 1)
			value[4] = 0xff
			return value
		}(), want: v2.ErrMalformedProto},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := v2.DecodeControl(tc.data)
			if !errors.Is(err, tc.want) {
				t.Fatalf("DecodeControl error = %v, want %v", err, tc.want)
			}
		})
	}

	dataFrame := &v2.RelayDataFrame{Version: v2.RELAY_V2_VERSION, Kind: &v2.RelayDataFrame_Ack{Ack: &v2.RelayDataAck{}}}
	dataEncoded, err := v2.EncodeDataFrame(dataFrame)
	if err != nil {
		t.Fatalf("EncodeDataFrame failed: %v", err)
	}
	if decoded, err := v2.DecodeData(dataEncoded); err != nil || decoded.GetAck() == nil {
		t.Fatalf("data round trip = %+v, err=%v", decoded, err)
	}
	if _, err := v2.DecodeData([]byte{0, 0, 0, 0}); err == nil {
		t.Fatal("DecodeData accepted an empty protobuf payload")
	}
}

func TestRelayInternalAPIReportsCapacityAndPersistentRotation(t *testing.T) {
	server := relay.NewServer(relay.Config{
		CredentialKey:     []byte(testCredentialKey),
		EnrollmentToken:   testEnrollmentToken,
		InternalToken:     testInternalToken,
		CredentialTTL:     time.Hour,
		MaxRevokedDevices: 1,
		ProtocolVersion:   relay.RelayBootstrapProtocolVersion,
	})
	t.Cleanup(server.Close)
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	publicKeyA, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	publicKeyB, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	enrollRelayDevice(t, mux, "capacity-a", publicKeyA)
	enrollRelayDevice(t, mux, "capacity-b", publicKeyB)

	revoke := func(deviceID string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, relay.PathInternalRevokeDeviceV2+deviceID+"/revoke", nil)
		req.Header.Set("Authorization", "Bearer "+testInternalToken)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		return rec
	}
	if rec := revoke("capacity-a"); rec.Code != http.StatusNoContent {
		t.Fatalf("first revoke status = %d, want 204: %s", rec.Code, rec.Body.String())
	}
	if rec := revoke("capacity-b"); rec.Code != http.StatusTooManyRequests {
		t.Fatalf("revocation capacity status = %d, want 429: %s", rec.Code, rec.Body.String())
	}
	tooLong := relay.PathInternalRevokeDeviceV2 + strings.Repeat("x", 129) + "/revoke"
	if rec := serveRelayRequestWithAuth(mux, http.MethodPost, tooLong, testInternalToken); rec.Code != http.StatusBadRequest {
		t.Fatalf("overlong revoke status = %d, want 400", rec.Code)
	}

	persistent := relay.NewServer(relay.Config{
		CredentialKey:   []byte(testCredentialKey),
		EnrollmentToken: testEnrollmentToken,
		InternalToken:   testInternalToken,
		StorageMode:     "mysql",
	})
	t.Cleanup(persistent.Close)
	persistentMux := http.NewServeMux()
	persistent.RegisterRoutes(persistentMux)
	if rec := serveRelayRequestWithAuth(persistentMux, http.MethodPost, relay.PathInternalRotateTokenV2, testInternalToken); rec.Code != http.StatusConflict {
		t.Fatalf("persistent rotation status = %d, want 409: %s", rec.Code, rec.Body.String())
	}
}

func TestRelayInternalDevicesPreserveOrderAndRedactInvalidFingerprint(t *testing.T) {
	server, mux := newRelayTestServer(t)
	seeded := []relay.EnrolledDevice{
		{DeviceID: "z-device", PublicKey: "!", Platform: "test", ProtocolVersion: relay.RelayBootstrapProtocolVersion, EnrolledAt: time.Now()},
		{DeviceID: "a-device", PublicKey: "!", Platform: "test", ProtocolVersion: relay.RelayBootstrapProtocolVersion, EnrolledAt: time.Now()},
	}
	if err := server.SeedEnrollments(context.Background(), seeded); err != nil {
		t.Fatalf("seed invalid fingerprints: %v", err)
	}
	req := httptest.NewRequest(http.MethodGet, relay.PathInternalDevicesV2, nil)
	req.Header.Set("Authorization", "Bearer "+testInternalToken)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("devices status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	var response struct {
		Items []struct {
			DeviceID             string `json:"device_id"`
			PublicKeyFingerprint string `json:"public_key_fingerprint"`
		} `json:"items"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode devices response: %v", err)
	}
	if len(response.Items) != 2 || response.Items[0].DeviceID != "a-device" || response.Items[1].DeviceID != "z-device" {
		t.Fatalf("devices were not sorted by identity: %+v", response.Items)
	}
	for _, item := range response.Items {
		if item.PublicKeyFingerprint != "" {
			t.Fatalf("invalid public key produced a fingerprint: %+v", item)
		}
	}
}

func TestRelayInternalAttestationRejectsMalformedProofFields(t *testing.T) {
	_, mux := newRelayTestServer(t)
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	credential := enrollRelayDevice(t, mux, "attestation-boundary-device", publicKey)
	now := time.Now().Unix()
	baseBody := func(timestamp int64, nonce, transcript string) []byte {
		req := attestationRequest("attestation-boundary-device", credential, publicKey, privateKey, timestamp, nonce, transcript)
		body, err := io.ReadAll(req.Body)
		if err != nil {
			t.Fatal(err)
		}
		return body
	}
	mutate := func(body []byte, field string, value any) []byte {
		var payload map[string]any
		if err := json.Unmarshal(body, &payload); err != nil {
			t.Fatal(err)
		}
		payload[field] = value
		mutated, err := json.Marshal(payload)
		if err != nil {
			t.Fatal(err)
		}
		return mutated
	}
	validNonce := encodedNonce(0x67)
	cases := []struct {
		name string
		body []byte
		want int
	}{
		{"malformed JSON", []byte("{"), http.StatusBadRequest},
		{"missing required proof", []byte(`{"device_id":"attestation-boundary-device"}`), http.StatusUnauthorized},
		{"invalid credential", mutate(baseBody(now, validNonce, relay.PathPublicTelemetryEnroll), "relay_credential", "bad"), http.StatusUnauthorized},
		{"invalid public key", mutate(baseBody(now, encodedNonce(0x68), relay.PathPublicTelemetryEnroll), "public_key", "bad"), http.StatusUnauthorized},
		{"stale timestamp", baseBody(now-601, encodedNonce(0x69), relay.PathPublicTelemetryEnroll), http.StatusUnauthorized},
		{"invalid nonce", mutate(baseBody(now, encodedNonce(0x6a), relay.PathPublicTelemetryEnroll), "nonce", "bad"), http.StatusUnauthorized},
		{"unsupported transcript", baseBody(now, encodedNonce(0x6b), "/unexpected"), http.StatusUnauthorized},
		{"invalid signature", mutate(baseBody(now, encodedNonce(0x6c), relay.PathPublicTelemetryEnroll), "signature", "bad"), http.StatusUnauthorized},
		{"default transcript", mutate(baseBody(now, encodedNonce(0x6d), relay.PathPublicTelemetryEnroll), "transcript_path", ""), http.StatusOK},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, relay.PathInternalTelemetryAttest, bytes.NewReader(tc.body))
			rec := serveAttestation(mux, req, testInternalToken)
			if rec.Code != tc.want {
				t.Fatalf("attestation status = %d, want %d: %s", rec.Code, tc.want, rec.Body.String())
			}
		})
	}
}

func TestRelayConfigRejectsInvalidPublicURL(t *testing.T) {
	t.Setenv("RELAY_ENROLLMENT_TOKEN", testEnrollmentToken)
	t.Setenv("RELAY_CREDENTIAL_KEY", base64.RawURLEncoding.EncodeToString([]byte(testCredentialKey)))
	t.Setenv("RELAY_PUBLIC_URL", "://invalid")
	t.Setenv("RELAY_INTERNAL_TOKEN", testInternalToken)
	if _, err := relay.ConfigFromEnvironment(); err == nil {
		t.Fatal("ConfigFromEnvironment accepted an invalid public URL")
	}
}

func serveRelayRequestWithAuth(mux *http.ServeMux, method, path, token string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}
