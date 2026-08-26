package admin

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
	"time"
)

func newTestAdminServer(t *testing.T, user, password string) (*Server, *http.ServeMux) {
	t.Helper()
	cfg := Config{
		AdminUser:          user,
		AdminPassword:      password,
		AuthKey:            []byte("01234567890123456789012345678901"),
		SessionTTL:         time.Hour,
		MaxSessions:        10,
		LoginMaxAttempts:   3,
		LoginWindow:        time.Minute,
		LoginBlockDuration: 5 * time.Minute,
		TrustedProxyCIDRs:  []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8")},
	}
	server := NewServer(cfg)
	t.Cleanup(func() { server.Close() })

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	return server, mux
}

func TestAdminAuthLoginSuccessAndSessionCheck(t *testing.T) {
	user := "superadmin"
	pass := "supersecretpassword123"
	_, mux := newTestAdminServer(t, user, pass)

	// 1. Successful Login
	body, _ := json.Marshal(map[string]string{
		"username": user,
		"password": pass,
	})
	req := httptest.NewRequest(http.MethodPost, PathAuthLogin, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("login status = %d, want 200. Body: %s", rec.Code, rec.Body.String())
	}
	var loginResp map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &loginResp); err != nil || loginResp["username"] != user {
		t.Fatalf("unexpected login response: %+v", loginResp)
	}

	cookies := rec.Result().Cookies()
	var sessionCookie *http.Cookie
	for _, c := range cookies {
		if c.Name == sessionCookieName {
			sessionCookie = c
			break
		}
	}
	if sessionCookie == nil || sessionCookie.Value == "" {
		t.Fatalf("expected non-empty session cookie")
	}

	// 2. Active Session Check
	sessionReq := httptest.NewRequest(http.MethodGet, PathAuthSession, nil)
	sessionReq.AddCookie(sessionCookie)
	sessionRec := httptest.NewRecorder()
	mux.ServeHTTP(sessionRec, sessionReq)

	if sessionRec.Code != http.StatusOK {
		t.Fatalf("session check status = %d, want 200", sessionRec.Code)
	}
	var sessionResp struct {
		Authenticated bool   `json:"authenticated"`
		Username      string `json:"username"`
	}
	if err := json.Unmarshal(sessionRec.Body.Bytes(), &sessionResp); err != nil || !sessionResp.Authenticated || sessionResp.Username != user {
		t.Fatalf("expected session authenticated=true for user %s, got %+v", user, sessionResp)
	}

	// 3. Logout
	logoutReq := httptest.NewRequest(http.MethodPost, PathAuthLogout, nil)
	logoutReq.AddCookie(sessionCookie)
	logoutRec := httptest.NewRecorder()
	mux.ServeHTTP(logoutRec, logoutReq)

	if logoutRec.Code != http.StatusNoContent {
		t.Fatalf("logout status = %d, want 204", logoutRec.Code)
	}

	// 4. Session Check After Logout
	sessionReq2 := httptest.NewRequest(http.MethodGet, PathAuthSession, nil)
	sessionReq2.AddCookie(sessionCookie)
	sessionRec2 := httptest.NewRecorder()
	mux.ServeHTTP(sessionRec2, sessionReq2)

	var sessionResp2 struct {
		Authenticated bool   `json:"authenticated"`
		Username      string `json:"username"`
	}
	if err := json.Unmarshal(sessionRec2.Body.Bytes(), &sessionResp2); err != nil || sessionResp2.Authenticated {
		t.Fatalf("expected session authenticated=false after logout, got %+v", sessionResp2)
	}
}

func TestAdminAuthLoginFailureAndRateLimiting(t *testing.T) {
	user := "adminuser"
	pass := "correctpassword123"
	_, mux := newTestAdminServer(t, user, pass)

	// Incorrect password
	badBody, _ := json.Marshal(map[string]string{
		"username": user,
		"password": "wrongpassword",
	})

	for attempt := 1; attempt <= 3; attempt++ {
		req := httptest.NewRequest(http.MethodPost, PathAuthLogin, bytes.NewReader(badBody))
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)

		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("attempt %d status = %d, want 401", attempt, rec.Code)
		}
	}

	// 4th attempt should be rate limited (429)
	req := httptest.NewRequest(http.MethodPost, PathAuthLogin, bytes.NewReader(badBody))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("4th attempt status = %d, want 429", rec.Code)
	}
}

func TestAdminAuthTrustedProxyAndTLS(t *testing.T) {
	user := "adminuser"
	pass := "correctpassword123"
	_, mux := newTestAdminServer(t, user, pass)

	body, _ := json.Marshal(map[string]string{
		"username": user,
		"password": pass,
	})
	req := httptest.NewRequest(http.MethodPost, PathAuthLogin, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	// Request from trusted proxy with HTTPS proto
	req.RemoteAddr = "10.0.1.5:45678"
	req.Header.Set("X-Forwarded-For", "203.0.113.195")
	req.Header.Set("X-Forwarded-Proto", "https")

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("login status = %d, want 200", rec.Code)
	}
	cookies := rec.Result().Cookies()
	var sessionCookie *http.Cookie
	for _, c := range cookies {
		if c.Name == sessionCookieName {
			sessionCookie = c
			break
		}
	}
	if sessionCookie == nil || !sessionCookie.Secure {
		t.Fatalf("expected Secure cookie behind trusted proxy with HTTPS")
	}
}

func TestAdminAuthSessionCapacity(t *testing.T) {
	store := newMemorySessionStore(2)
	ctx := context.Background()

	if err := store.Create(ctx, "token-1", time.Hour); err != nil {
		t.Fatalf("create token-1 error: %v", err)
	}
	if err := store.Create(ctx, "token-2", time.Hour); err != nil {
		t.Fatalf("create token-2 error: %v", err)
	}
	if err := store.Create(ctx, "token-3", time.Hour); err != errSessionCapacity {
		t.Fatalf("create token-3 expected errSessionCapacity, got: %v", err)
	}
}
