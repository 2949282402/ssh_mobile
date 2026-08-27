package telemetry

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

type testDeviceAttestor struct {
	result DeviceAttestation
	err    error
	seen   []DeviceAttestationRequest
}

func (a *testDeviceAttestor) ValidateDeviceCredential(
	_ context.Context,
	request DeviceAttestationRequest,
) (DeviceAttestation, error) {
	a.seen = append(a.seen, request)
	if a.err != nil {
		return DeviceAttestation{}, a.err
	}
	return a.result, nil
}

func TestHandlePublicEnroll_IssuesAndStoresOneTimeSecret(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	attestor := &testDeviceAttestor{result: DeviceAttestation{DeviceID: "device-a"}}
	handler := NewHandler(service, attestor)
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	body, err := json.Marshal(TelemetryEnrollmentRequest{
		DeviceID:        "device-a",
		RelayCredential: "relay-credential",
		PublicKey:       "public-key",
		Timestamp:       time.Now().Unix(),
		Nonce:           "nonce",
		Signature:       "signature",
	})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, RoutePublicEnroll, bytes.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	var response TelemetryEnrollmentResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.DeviceID != "device-a" || len(response.Secret) != 64 {
		t.Fatalf("unexpected enrollment response: %+v", response)
	}
	stored, err := store.GetDeviceCredential(context.Background(), "device-a")
	if err != nil {
		t.Fatal(err)
	}
	if stored != hashSecret(response.Secret) {
		t.Fatal("telemetry store must retain only the secret hash")
	}
	if len(attestor.seen) != 1 || attestor.seen[0].DeviceID != "device-a" {
		t.Fatalf("attestor did not receive the bound request: %+v", attestor.seen)
	}
}

func TestHandlePublicEnroll_FailsClosedWithoutRelayAttestor(t *testing.T) {
	service, _ := newTestService(testAuthSecret)
	handler := NewHandler(service)
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	req := httptest.NewRequest(
		http.MethodPost,
		RoutePublicEnroll,
		bytes.NewBufferString(`{"deviceId":"device-a"}`),
	)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 without Relay attestor, got %d", rec.Code)
	}
}

func TestHandlePublicEnroll_RejectsRelayAttestationFailure(t *testing.T) {
	service, _ := newTestService(testAuthSecret)
	attestor := &testDeviceAttestor{err: errors.New("relay rejected device")}
	handler := NewHandler(service, attestor)
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	req := httptest.NewRequest(
		http.MethodPost,
		RoutePublicEnroll,
		bytes.NewBufferString(`{"deviceId":"device-a","relayCredential":"credential","publicKey":"key","timestamp":1,"nonce":"nonce","signature":"signature"}`),
	)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for rejected Relay attestation, got %d", rec.Code)
	}
}

func TestHandlePublicEnroll_RejectsMissingProof(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	attestor := &testDeviceAttestor{result: DeviceAttestation{DeviceID: "device-a"}}
	handler := NewHandler(service, attestor)
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	req := httptest.NewRequest(
		http.MethodPost,
		RoutePublicEnroll,
		bytes.NewBufferString(`{"deviceId":"device-a"}`),
	)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for missing proof, got %d", rec.Code)
	}
	if len(attestor.seen) != 0 {
		t.Fatal("missing proof must not call Relay attestation")
	}
	if _, err := store.GetDeviceCredential(context.Background(), "device-a"); !errors.Is(err, ErrDeviceCredentialNotFound) {
		t.Fatalf("missing proof must not create a credential, got %v", err)
	}
}

type failingCredentialStore struct {
	*MemoryStore
	err error
}

func (s *failingCredentialStore) CreateDeviceCredential(context.Context, string, string) error {
	return s.err
}

func TestHandlePublicEnroll_FailsClosedWhenCredentialStoreFails(t *testing.T) {
	catalog := DefaultCatalog()
	store := &failingCredentialStore{
		MemoryStore: NewMemoryStore(catalog),
		err:         errors.New("analytics store unavailable"),
	}
	service := NewServiceWithSecret(store, catalog, &NoopRedisCache{}, testAuthSecret)
	attestor := &testDeviceAttestor{result: DeviceAttestation{DeviceID: "device-a"}}
	handler := NewHandler(service, attestor)
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	body, err := json.Marshal(TelemetryEnrollmentRequest{
		DeviceID:        "device-a",
		RelayCredential: "relay-credential",
		PublicKey:       "public-key",
		Timestamp:       time.Now().Unix(),
		Nonce:           "nonce",
		Signature:       "signature",
	})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, RoutePublicEnroll, bytes.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 for credential store failure, got %d", rec.Code)
	}
	if _, err := store.MemoryStore.GetDeviceCredential(context.Background(), "device-a"); !errors.Is(err, ErrDeviceCredentialNotFound) {
		t.Fatalf("store failure must not leave a credential, got %v", err)
	}
}

func TestHandlePublicEnroll_IsCreateOnlyAndExplicitRotationIsSeparate(t *testing.T) {
	service, store := newTestService(testAuthSecret)
	attestor := &testDeviceAttestor{result: DeviceAttestation{DeviceID: "device-a"}}
	handler := NewHandler(service, attestor)
	mux := http.NewServeMux()
	handler.RegisterPublicRoutes(mux)

	body, err := json.Marshal(TelemetryEnrollmentRequest{
		DeviceID:        "device-a",
		RelayCredential: "relay-credential",
		PublicKey:       "public-key",
		Timestamp:       time.Now().Unix(),
		Nonce:           "nonce",
		Signature:       "signature",
	})
	if err != nil {
		t.Fatal(err)
	}
	first := httptest.NewRecorder()
	mux.ServeHTTP(first, httptest.NewRequest(http.MethodPost, RoutePublicEnroll, bytes.NewReader(body)))
	if first.Code != http.StatusCreated {
		t.Fatalf("first enrollment status = %d: %s", first.Code, first.Body.String())
	}
	second := httptest.NewRecorder()
	mux.ServeHTTP(second, httptest.NewRequest(http.MethodPost, RoutePublicEnroll, bytes.NewReader(body)))
	if second.Code != http.StatusConflict {
		t.Fatalf("implicit repeat status = %d: %s", second.Code, second.Body.String())
	}

	rotated := httptest.NewRecorder()
	mux.ServeHTTP(rotated, httptest.NewRequest(http.MethodPost, RoutePublicRotate, bytes.NewReader(body)))
	if rotated.Code != http.StatusOK {
		t.Fatalf("explicit rotation status = %d: %s", rotated.Code, rotated.Body.String())
	}
	var response TelemetryEnrollmentResponse
	if err := json.Unmarshal(rotated.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	stored, err := store.GetDeviceCredential(context.Background(), "device-a")
	if err != nil || stored != hashSecret(response.Secret) {
		t.Fatalf("rotation did not replace only the stored hash: hash=%q err=%v", stored, err)
	}
}
