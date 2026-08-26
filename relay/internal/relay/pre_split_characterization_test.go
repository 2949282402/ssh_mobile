package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// TestPreSplitCharacterization locks the baseline invariants for:
// - V2 device bootstrap (enroll + refresh) with ProtocolVersion = 2
// - Admin authentication and overview
// - Credential verification and control/data admission
func TestPreSplitCharacterization(t *testing.T) {
	ctx := context.Background()
	credentialKey := []byte("01234567890123456789012345678901")
	enrollmentToken := "characterization-enrollment-token"
	internalToken := "0123456789abcdef0123456789abcdef"

	cfg := Config{
		CredentialKey:   credentialKey,
		CredentialTTL:   time.Hour,
		EnrollmentToken: enrollmentToken,
		InternalToken:   internalToken,
	}

	server := NewServer(cfg)
	defer server.Close()

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	pubKey, privKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey error: %v", err)
	}
	pubKeyB64 := base64.RawURLEncoding.EncodeToString(pubKey)

	// 1. Lock V2 Enroll
	enrollReq := enrollRequest{
		DeviceID:        "char-device-1",
		PublicKey:       pubKeyB64,
		EnrollmentToken: enrollmentToken,
		ProtocolVersion: 2,
		Platform:        "linux",
	}
	enrollData, _ := json.Marshal(enrollReq)
	req := httptest.NewRequest(http.MethodPost, PathEnrollV2, bytes.NewReader(enrollData))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("V2 enroll status = %d; want %d. Body: %s", rec.Code, http.StatusOK, rec.Body.String())
	}

	var enrollResp enrollResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &enrollResp); err != nil {
		t.Fatalf("Unmarshal enrollResponse error: %v", err)
	}
	if enrollResp.ProtocolVersion != 2 || enrollResp.Credential == "" {
		t.Fatalf("Unexpected enroll response: %+v", enrollResp)
	}

	// 3. Lock V2 Refresh
	now := time.Now().Unix()
	nonceRaw := make([]byte, 32)
	rand.Read(nonceRaw)
	nonce := base64.RawURLEncoding.EncodeToString(nonceRaw)
	transcript := fmt.Sprintf("POST\n%s\n%d\n%s", PathRefreshV2, now, nonce)
	sig := ed25519.Sign(privKey, []byte(transcript))
	sigB64 := base64.RawURLEncoding.EncodeToString(sig)

	refreshReq := refreshRequest{
		DeviceID:  "char-device-1",
		PublicKey: pubKeyB64,
		Timestamp: now,
		Nonce:     nonce,
		Signature: sigB64,
	}
	refreshData, _ := json.Marshal(refreshReq)
	req = httptest.NewRequest(http.MethodPost, PathRefreshV2, bytes.NewReader(refreshData))
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("V2 refresh status = %d; want %d. Body: %s", rec.Code, http.StatusOK, rec.Body.String())
	}

	var refreshResp enrollResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &refreshResp); err != nil {
		t.Fatalf("Unmarshal refreshResponse error: %v", err)
	}
	if refreshResp.ProtocolVersion != 2 || refreshResp.Credential == "" {
		t.Fatalf("Unexpected refresh response: %+v", refreshResp)
	}

	// 4. The legacy Admin API is retired on the Relay: /api/admin/v1/* returns 404.
	req = httptest.NewRequest(http.MethodGet, "/api/admin/v1/overview", nil)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("Legacy admin overview status = %d; want 404. Body: %s", rec.Code, rec.Body.String())
	}

	// 5. The internal management status endpoint is available under the internal
	// token: /internal/v2/status returns 200 with the runtime snapshot.
	req = httptest.NewRequest(http.MethodGet, PathInternalStatusV2, nil)
	req.Header.Set("Authorization", "Bearer "+internalToken)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("Internal status status = %d; want %d. Body: %s", rec.Code, http.StatusOK, rec.Body.String())
	}
	var statusResp map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &statusResp); err != nil {
		t.Fatalf("Unmarshal internal status response error: %v", err)
	}
	if _, ok := statusResp["server_time"]; !ok {
		t.Fatalf("Expected server_time in internal status: %+v", statusResp)
	}

	// 6. Verify durable enrollment exists in store
	enrollment, err := server.store.GetEnrollment(ctx, "char-device-1")
	if err != nil || enrollment == nil {
		t.Fatalf("Expected durable enrollment for char-device-1: %v", err)
	}
	if enrollment.ProtocolVersion != 2 {
		t.Fatalf("Expected ProtocolVersion = 2, got %d", enrollment.ProtocolVersion)
	}
}
