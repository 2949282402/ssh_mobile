package relay

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestCredentialBindsDeviceAndKey(t *testing.T) {
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	credential, err := issueCredential([]byte("01234567890123456789012345678901"), "device-a", publicKey, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	claims, restored, err := verifyCredential([]byte("01234567890123456789012345678901"), credential)
	if err != nil {
		t.Fatal(err)
	}
	if claims.DeviceID != "device-a" || base64.RawURLEncoding.EncodeToString(restored) != base64.RawURLEncoding.EncodeToString(publicKey) {
		t.Fatal("credential lost identity binding")
	}
}

func TestHubDoesNotPersistExpiredSession(t *testing.T) {
	hub := newHub(Config{SessionTTL: time.Nanosecond})
	defer hub.close()
	hub.sessions["0123456789abcdef0123456789abcdef"] = session{sender: "a", receiver: "b", expiresAt: time.Now().Add(-time.Second)}
	hub.mutex.Lock()
	for id, value := range hub.sessions {
		if time.Now().After(value.expiresAt) {
			delete(hub.sessions, id)
		}
	}
	_, found := hub.sessions["0123456789abcdef0123456789abcdef"]
	hub.mutex.Unlock()
	if found {
		t.Fatal("expired session was retained")
	}
}

func TestEnrollDevice(t *testing.T) {
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	server := NewServer(Config{
		CredentialKey:   []byte("01234567890123456789012345678901"),
		EnrollmentToken: "test-token",
		CredentialTTL:   time.Hour,
	})
	defer server.Close()

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	body, _ := json.Marshal(enrollRequest{
		DeviceID:        "test-device",
		PublicKey:       base64.RawURLEncoding.EncodeToString(publicKey),
		EnrollmentToken: "test-token",
		ProtocolVersion: 1,
		Platform:        "windows",
	})

	req := httptest.NewRequest("POST", "/v1/devices/enroll", bytes.NewReader(body))
	rec := httptest.NewRecorder()

	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}

	var resp enrollResponse
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if resp.Credential == "" || resp.ProtocolVersion != 1 {
		t.Fatalf("invalid enroll response: %+v", resp)
	}
}

func TestDashboardAndApiStats(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:   []byte("01234567890123456789012345678901"),
		EnrollmentToken: "test-token",
	})
	defer server.Close()

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	// Test GET / HTML dashboard
	reqDash := httptest.NewRequest("GET", "/", nil)
	recDash := httptest.NewRecorder()
	mux.ServeHTTP(recDash, reqDash)

	if recDash.Code != http.StatusOK {
		t.Fatalf("expected status 200 for dashboard, got %d", recDash.Code)
	}
	if !bytes.Contains(recDash.Body.Bytes(), []byte("SSH Mobile")) {
		t.Fatalf("dashboard missing expected HTML content")
	}

	// Test GET /api/stats JSON
	reqStats := httptest.NewRequest("GET", "/api/stats", nil)
	recStats := httptest.NewRecorder()
	mux.ServeHTTP(recStats, reqStats)

	if recStats.Code != http.StatusOK {
		t.Fatalf("expected status 200 for stats, got %d", recStats.Code)
	}
	var stats statsResponse
	if err := json.NewDecoder(recStats.Body).Decode(&stats); err != nil {
		t.Fatalf("failed to decode stats JSON: %v", err)
	}
}
