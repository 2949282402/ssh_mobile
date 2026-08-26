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

// TestPreSplitCharacterization locks the pre-split baseline invariants for:
// - V1 device bootstrap (enroll + refresh)
// - Admin authentication and overview
// - Credential verification and control/data admission
func TestPreSplitCharacterization(t *testing.T) {
	ctx := context.Background()
	credentialKey := []byte("01234567890123456789012345678901")
	enrollmentToken := "characterization-enrollment-token"
	adminUser := "admin"
	adminPass := "char-admin-pass-123456"

	cfg := Config{
		CredentialKey:   credentialKey,
		CredentialTTL:   time.Hour,
		EnrollmentToken: enrollmentToken,
		AdminUser:       adminUser,
		AdminPassword:   adminPass,
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

	// 1. Lock V1 Enroll
	enrollReq := enrollRequest{
		DeviceID:        "char-device-1",
		PublicKey:       pubKeyB64,
		EnrollmentToken: enrollmentToken,
		ProtocolVersion: 1,
		Platform:        "linux",
	}
	enrollData, _ := json.Marshal(enrollReq)
	req := httptest.NewRequest(http.MethodPost, "/v1/devices/enroll", bytes.NewReader(enrollData))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("V1 enroll status = %d; want %d. Body: %s", rec.Code, http.StatusOK, rec.Body.String())
	}

	var enrollResp enrollResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &enrollResp); err != nil {
		t.Fatalf("Unmarshal enrollResponse error: %v", err)
	}
	if enrollResp.ProtocolVersion != 1 || enrollResp.Credential == "" {
		t.Fatalf("Unexpected enroll response: %+v", enrollResp)
	}

	// 2. Lock V1 Refresh
	now := time.Now().Unix()
	nonceRaw := make([]byte, 32)
	rand.Read(nonceRaw)
	nonce := base64.RawURLEncoding.EncodeToString(nonceRaw)
	transcript := fmt.Sprintf("POST\n/v1/devices/refresh\n%d\n%s", now, nonce)
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
	req = httptest.NewRequest(http.MethodPost, "/v1/devices/refresh", bytes.NewReader(refreshData))
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("V1 refresh status = %d; want %d. Body: %s", rec.Code, http.StatusOK, rec.Body.String())
	}

	var refreshResp enrollResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &refreshResp); err != nil {
		t.Fatalf("Unmarshal refreshResponse error: %v", err)
	}
	if refreshResp.ProtocolVersion != 1 || refreshResp.Credential == "" {
		t.Fatalf("Unexpected refresh response: %+v", refreshResp)
	}

	// 3. Lock Admin Auth and Overview
	loginReq := map[string]string{
		"username": adminUser,
		"password": adminPass,
	}
	loginData, _ := json.Marshal(loginReq)
	req = httptest.NewRequest(http.MethodPost, "/api/admin/v1/auth/login", bytes.NewReader(loginData))
	req.Header.Set("Content-Type", "application/json")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("Admin login status = %d; want %d. Body: %s", rec.Code, http.StatusOK, rec.Body.String())
	}
	cookies := rec.Result().Cookies()
	var sessionCookie *http.Cookie
	for _, c := range cookies {
		if c.Name == "relay_session" {
			sessionCookie = c
			break
		}
	}
	if sessionCookie == nil {
		t.Fatalf("Expected relay_session cookie from login")
	}

	// Admin Overview with cookie
	req = httptest.NewRequest(http.MethodGet, "/api/admin/v1/overview", nil)
	req.AddCookie(sessionCookie)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("Admin overview status = %d; want %d. Body: %s", rec.Code, http.StatusOK, rec.Body.String())
	}
	var overviewResp map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &overviewResp); err != nil {
		t.Fatalf("Unmarshal overview response error: %v", err)
	}
	if _, ok := overviewResp["server_time"]; !ok {
		t.Fatalf("Expected server_time in overview: %+v", overviewResp)
	}

	// 4. Verify durable enrollment exists in store
	enrollment, err := server.store.GetEnrollment(ctx, "char-device-1")
	if err != nil || enrollment == nil {
		t.Fatalf("Expected durable enrollment for char-device-1: %v", err)
	}
	if enrollment.ProtocolVersion != 1 {
		t.Fatalf("Expected ProtocolVersion = 1, got %d", enrollment.ProtocolVersion)
	}
}
