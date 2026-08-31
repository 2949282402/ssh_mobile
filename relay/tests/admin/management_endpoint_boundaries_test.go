package admin_test

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/admin"
)

type managementClientStub struct {
	status       RelayStatus
	devices      RelayDevices
	statusErr    error
	devicesErr   error
	tokenErr     error
	rotateErr    error
	revokeErr    error
	revokeCalls  int
	revokeHook   func()
	token        EnrollmentTokenInfo
	rotatedToken EnrollmentTokenInfo
}

func (c *managementClientStub) Status(_ context.Context) (RelayStatus, error) {
	return c.status, c.statusErr
}

func (c *managementClientStub) Devices(_ context.Context) (RelayDevices, error) {
	return c.devices, c.devicesErr
}

func (c *managementClientStub) RevokeDevice(_ context.Context, _ string) error {
	c.revokeCalls++
	if c.revokeHook != nil {
		c.revokeHook()
	}
	return c.revokeErr
}

func (c *managementClientStub) EnrollmentToken(_ context.Context) (EnrollmentTokenInfo, error) {
	return c.token, c.tokenErr
}

func (c *managementClientStub) RotateEnrollmentToken(_ context.Context) (EnrollmentTokenInfo, error) {
	return c.rotatedToken, c.rotateErr
}

func newManagementEndpointServer(t *testing.T, client *managementClientStub, maxSessions int) *http.ServeMux {
	t.Helper()
	server := NewServerWithClient(Config{
		Address:            ":0",
		AdminUser:          "admin",
		AdminPassword:      "password-long-enough",
		AuthKey:            []byte("01234567890123456789012345678901"),
		SessionTTL:         time.Hour,
		MaxSessions:        maxSessions,
		LoginMaxAttempts:   5,
		LoginWindow:        time.Minute,
		LoginBlockDuration: time.Minute,
	}, client)
	t.Cleanup(func() { _ = server.Close() })
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	return mux
}

func adminLoginCookie(t *testing.T, mux *http.ServeMux) *http.Cookie {
	t.Helper()
	body, err := json.Marshal(map[string]string{"username": "admin", "password": "password-long-enough"})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, PathAuthLogin, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("login status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	for _, cookie := range rec.Result().Cookies() {
		if cookie.Name == "relay_session" && cookie.Value != "" {
			return cookie
		}
	}
	t.Fatal("login did not return a session cookie")
	return nil
}

func serveAdminRequest(mux *http.ServeMux, method, path string, cookie *http.Cookie) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, nil)
	if cookie != nil {
		req.AddCookie(cookie)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

func TestAdminManagementEndpointsForwardPublicResponses(t *testing.T) {
	client := &managementClientStub{
		status:       RelayStatus{ServerTime: 12, Devices: RelayDeviceStat{Enrolled: 2}},
		devices:      RelayDevices{Total: 1, Items: []RelayDeviceItem{{DeviceID: "device-a"}}},
		token:        EnrollmentTokenInfo{EnrollmentToken: "token-a"},
		rotatedToken: EnrollmentTokenInfo{EnrollmentToken: "token-b"},
	}
	mux := newManagementEndpointServer(t, client, 4)
	cookie := adminLoginCookie(t, mux)

	for _, tc := range []struct {
		name   string
		method string
		path   string
		want   int
	}{
		{"overview", http.MethodGet, PathOverview, http.StatusOK},
		{"devices", http.MethodGet, PathDevices, http.StatusOK},
		{"enrollment token", http.MethodGet, PathEnrollmentToken, http.StatusOK},
		{"rotate token", http.MethodPost, PathRotateToken, http.StatusOK},
		{"revoke device", http.MethodPost, PathRevokeDevice + "device-a/revoke", http.StatusNoContent},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rec := serveAdminRequest(mux, tc.method, tc.path, cookie)
			if rec.Code != tc.want {
				t.Fatalf("status = %d, want %d: %s", rec.Code, tc.want, rec.Body.String())
			}
		})
	}
}

func TestAdminManagementEndpointsMapRelayFailures(t *testing.T) {
	cases := []struct {
		name   string
		method string
		path   string
		setErr func(*managementClientStub)
		want   int
	}{
		{"overview unavailable", http.MethodGet, PathOverview, func(c *managementClientStub) { c.statusErr = ErrRelayUnavailable }, http.StatusServiceUnavailable},
		{"overview unexpected", http.MethodGet, PathOverview, func(c *managementClientStub) { c.statusErr = errors.New("unexpected") }, http.StatusInternalServerError},
		{"devices unavailable", http.MethodGet, PathDevices, func(c *managementClientStub) { c.devicesErr = ErrRelayUnavailable }, http.StatusServiceUnavailable},
		{"devices unexpected", http.MethodGet, PathDevices, func(c *managementClientStub) { c.devicesErr = errors.New("unexpected") }, http.StatusInternalServerError},
		{"token unavailable", http.MethodGet, PathEnrollmentToken, func(c *managementClientStub) { c.tokenErr = ErrRelayUnavailable }, http.StatusServiceUnavailable},
		{"token unexpected", http.MethodGet, PathEnrollmentToken, func(c *managementClientStub) { c.tokenErr = errors.New("unexpected") }, http.StatusInternalServerError},
		{"rotate conflict", http.MethodPost, PathRotateToken, func(c *managementClientStub) { c.rotateErr = ErrConflict }, http.StatusConflict},
		{"rotate unavailable", http.MethodPost, PathRotateToken, func(c *managementClientStub) { c.rotateErr = ErrRelayUnavailable }, http.StatusServiceUnavailable},
		{"rotate unexpected", http.MethodPost, PathRotateToken, func(c *managementClientStub) { c.rotateErr = errors.New("unexpected") }, http.StatusInternalServerError},
		{"revoke missing", http.MethodPost, PathRevokeDevice + "device-a/revoke", func(c *managementClientStub) { c.revokeErr = ErrDeviceNotFound }, http.StatusNotFound},
		{"revoke limited", http.MethodPost, PathRevokeDevice + "device-a/revoke", func(c *managementClientStub) { c.revokeErr = ErrResourceLimit }, http.StatusTooManyRequests},
		{"revoke unavailable", http.MethodPost, PathRevokeDevice + "device-a/revoke", func(c *managementClientStub) { c.revokeErr = ErrRelayUnavailable }, http.StatusServiceUnavailable},
		{"revoke unexpected", http.MethodPost, PathRevokeDevice + "device-a/revoke", func(c *managementClientStub) { c.revokeErr = errors.New("unexpected") }, http.StatusInternalServerError},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client := &managementClientStub{}
			tc.setErr(client)
			mux := newManagementEndpointServer(t, client, 2)
			cookie := adminLoginCookie(t, mux)
			rec := serveAdminRequest(mux, tc.method, tc.path, cookie)
			if rec.Code != tc.want {
				t.Fatalf("status = %d, want %d: %s", rec.Code, tc.want, rec.Body.String())
			}
		})
	}
}

func TestAdminManagementMiddlewareRejectsUnsafeRequests(t *testing.T) {
	client := &managementClientStub{}
	mux := newManagementEndpointServer(t, client, 2)
	cookie := adminLoginCookie(t, mux)

	badContent := httptest.NewRequest(http.MethodPost, PathRotateToken, bytes.NewBufferString(`{"request":"body"}`))
	badContent.Header.Set("Content-Type", "text/plain")
	badContent.AddCookie(cookie)
	badContentRec := httptest.NewRecorder()
	mux.ServeHTTP(badContentRec, badContent)
	if badContentRec.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("invalid content type status = %d, want 415", badContentRec.Code)
	}

	badOrigin := httptest.NewRequest(http.MethodPost, PathRotateToken, nil)
	badOrigin.Host = "admin.example.test"
	badOrigin.Header.Set("Origin", "https://other.example.test")
	badOrigin.AddCookie(cookie)
	badOriginRec := httptest.NewRecorder()
	mux.ServeHTTP(badOriginRec, badOrigin)
	if badOriginRec.Code != http.StatusForbidden {
		t.Fatalf("invalid origin status = %d, want 403", badOriginRec.Code)
	}

	missingSession := serveAdminRequest(mux, http.MethodGet, PathOverview, &http.Cookie{Name: "relay_session", Value: "missing-session"})
	if missingSession.Code != http.StatusUnauthorized {
		t.Fatalf("unknown session status = %d, want 401", missingSession.Code)
	}

	tooLongID := PathRevokeDevice + string(bytes.Repeat([]byte{'x'}, 129)) + "/revoke"
	if rec := serveAdminRequest(mux, http.MethodPost, tooLongID, cookie); rec.Code != http.StatusBadRequest {
		t.Fatalf("overlong device ID status = %d, want 400", rec.Code)
	}
}

func TestAdminAuthenticationBoundaryResponses(t *testing.T) {
	client := &managementClientStub{}
	mux := newManagementEndpointServer(t, client, 1)

	malformed := httptest.NewRequest(http.MethodPost, PathAuthLogin, bytes.NewBufferString("["))
	malformed.Header.Set("Content-Type", "application/json")
	malformedRec := httptest.NewRecorder()
	mux.ServeHTTP(malformedRec, malformed)
	if malformedRec.Code != http.StatusBadRequest {
		t.Fatalf("malformed login status = %d, want 400", malformedRec.Code)
	}

	firstCookie := adminLoginCookie(t, mux)
	secondLogin := httptest.NewRequest(http.MethodPost, PathAuthLogin, bytes.NewBufferString(`{"username":"admin","password":"password-long-enough"}`))
	secondLogin.Header.Set("Content-Type", "application/json")
	secondRec := httptest.NewRecorder()
	mux.ServeHTTP(secondRec, secondLogin)
	if secondRec.Code != http.StatusTooManyRequests {
		t.Fatalf("session capacity status = %d, want 429", secondRec.Code)
	}

	logoutRec := serveAdminRequest(mux, http.MethodPost, PathAuthLogout, nil)
	if logoutRec.Code != http.StatusNoContent {
		t.Fatalf("logout without cookie status = %d, want 204", logoutRec.Code)
	}
	if rec := serveAdminRequest(mux, http.MethodGet, PathAuthSession, firstCookie); rec.Code != http.StatusOK {
		t.Fatalf("session with active cookie status = %d, want 200", rec.Code)
	}

	unconfigured := NewServerWithClient(Config{AuthKey: []byte("01234567890123456789012345678901")}, client)
	t.Cleanup(func() { _ = unconfigured.Close() })
	unconfiguredMux := http.NewServeMux()
	unconfigured.RegisterRoutes(unconfiguredMux)
	req := httptest.NewRequest(http.MethodPost, PathAuthLogin, bytes.NewBufferString(`{"username":"admin","password":"password-long-enough"}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	unconfiguredMux.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("unconfigured login status = %d, want 503", rec.Code)
	}
}

func TestAdminAuthenticationHandlesProxyAndTLSBoundaries(t *testing.T) {
	client := &managementClientStub{}
	mux := newManagementEndpointServer(t, client, 4)

	proxyRequest := httptest.NewRequest(http.MethodPost, PathAuthLogin, bytes.NewBufferString(`{"username":"admin","password":"password-long-enough"}`))
	proxyRequest.Header.Set("Content-Type", "application/json")
	proxyRequest.RemoteAddr = "10.0.0.5:1234"
	proxyRequest.Header.Set("X-Forwarded-For", "not-an-ip")
	proxyRec := httptest.NewRecorder()
	mux.ServeHTTP(proxyRec, proxyRequest)
	if proxyRec.Code != http.StatusOK {
		t.Fatalf("proxy login status = %d, want 200", proxyRec.Code)
	}

	tlsRequest := httptest.NewRequest(http.MethodPost, PathAuthLogin, bytes.NewBufferString(`{"username":"admin","password":"password-long-enough"}`))
	tlsRequest.Header.Set("Content-Type", "application/json")
	tlsRequest.RemoteAddr = "not-an-address"
	tlsRequest.TLS = &tls.ConnectionState{}
	tlsRec := httptest.NewRecorder()
	mux.ServeHTTP(tlsRec, tlsRequest)
	if tlsRec.Code != http.StatusOK {
		t.Fatalf("TLS login status = %d, want 200", tlsRec.Code)
	}
	secure := false
	for _, cookie := range tlsRec.Result().Cookies() {
		if cookie.Name == "relay_session" {
			secure = cookie.Secure
		}
	}
	if !secure {
		t.Fatal("TLS login did not mark the session cookie Secure")
	}
}

func TestAdminAuthenticationUsesTrustedForwardingHeadersSafely(t *testing.T) {
	server := NewServerWithClient(Config{
		Address:            ":0",
		AdminUser:          "admin",
		AdminPassword:      "password-long-enough",
		AuthKey:            []byte("01234567890123456789012345678901"),
		SessionTTL:         time.Hour,
		MaxSessions:        4,
		TrustedProxyCIDRs:  []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8")},
		LoginMaxAttempts:   5,
		LoginWindow:        time.Minute,
		LoginBlockDuration: time.Minute,
	}, &managementClientStub{})
	t.Cleanup(func() { _ = server.Close() })
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	invalidForwarded := httptest.NewRequest(http.MethodPost, PathAuthLogin, bytes.NewBufferString(`{"username":"admin","password":"password-long-enough"}`))
	invalidForwarded.Header.Set("Content-Type", "application/json")
	invalidForwarded.RemoteAddr = "10.0.0.5:1234"
	invalidForwarded.Header.Set("X-Forwarded-For", "not-an-ip")
	invalidForwarded.Header.Set("X-Forwarded-Proto", "https")
	invalidRec := httptest.NewRecorder()
	mux.ServeHTTP(invalidRec, invalidForwarded)
	if invalidRec.Code != http.StatusOK {
		t.Fatalf("invalid forwarded address status = %d, want 200", invalidRec.Code)
	}

	forwardedTLS := httptest.NewRequest(http.MethodPost, PathAuthLogin, bytes.NewBufferString(`{"username":"admin","password":"password-long-enough"}`))
	forwardedTLS.Header.Set("Content-Type", "application/json")
	forwardedTLS.RemoteAddr = "10.0.0.6:1234"
	forwardedTLS.Header.Set("X-Forwarded-For", "192.0.2.8")
	forwardedTLS.Header.Set("X-Forwarded-Proto", "HTTPS")
	forwardedRec := httptest.NewRecorder()
	mux.ServeHTTP(forwardedRec, forwardedTLS)
	if forwardedRec.Code != http.StatusOK {
		t.Fatalf("forwarded TLS status = %d, want 200", forwardedRec.Code)
	}
	secure := false
	for _, cookie := range forwardedRec.Result().Cookies() {
		if cookie.Name == "relay_session" {
			secure = cookie.Secure
		}
	}
	if !secure {
		t.Fatal("trusted HTTPS forwarding did not mark the session cookie Secure")
	}

	malformedRemote := httptest.NewRequest(http.MethodPost, PathAuthLogin, bytes.NewBufferString(`{"username":"admin","password":"password-long-enough"}`))
	malformedRemote.Header.Set("Content-Type", "application/json")
	malformedRemote.RemoteAddr = "malformed-remote-address"
	malformedRemoteRec := httptest.NewRecorder()
	mux.ServeHTTP(malformedRemoteRec, malformedRemote)
	if malformedRemoteRec.Code != http.StatusOK {
		t.Fatalf("malformed remote address status = %d, want 200", malformedRemoteRec.Code)
	}
}

func TestAdminLoginFailureWindowEvictsExpiredEntries(t *testing.T) {
	server := NewServerWithClient(Config{
		Address:            ":0",
		AdminUser:          "admin",
		AdminPassword:      "password-long-enough",
		AuthKey:            []byte("01234567890123456789012345678901"),
		SessionTTL:         time.Hour,
		MaxSessions:        2,
		LoginMaxAttempts:   1,
		LoginWindow:        time.Nanosecond,
		LoginBlockDuration: time.Nanosecond,
		MaxLoginEntries:    1,
	}, &managementClientStub{})
	t.Cleanup(func() { _ = server.Close() })
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	badBody := bytes.NewBufferString(`{"username":"admin","password":"wrong-password"}`)
	first := httptest.NewRequest(http.MethodPost, PathAuthLogin, badBody)
	first.Header.Set("Content-Type", "application/json")
	first.RemoteAddr = "192.0.2.10:1"
	firstRec := httptest.NewRecorder()
	mux.ServeHTTP(firstRec, first)
	if firstRec.Code != http.StatusUnauthorized {
		t.Fatalf("first failed login status = %d, want 401", firstRec.Code)
	}

	time.Sleep(2 * time.Millisecond)
	second := httptest.NewRequest(http.MethodPost, PathAuthLogin, bytes.NewBufferString(`{"username":"admin","password":"wrong-password"}`))
	second.Header.Set("Content-Type", "application/json")
	second.RemoteAddr = "192.0.2.10:1"
	secondRec := httptest.NewRecorder()
	mux.ServeHTTP(secondRec, second)
	if secondRec.Code != http.StatusUnauthorized {
		t.Fatalf("expired failed-login entry status = %d, want 401", secondRec.Code)
	}
}

func TestAdminSessionExpirationReleasesCapacity(t *testing.T) {
	server := NewServerWithClient(Config{
		Address:          ":0",
		AdminUser:        "admin",
		AdminPassword:    "password-long-enough",
		AuthKey:          []byte("01234567890123456789012345678901"),
		SessionTTL:       time.Millisecond,
		MaxSessions:      1,
		LoginMaxAttempts: 5,
		LoginWindow:      time.Minute,
	}, &managementClientStub{})
	t.Cleanup(func() { _ = server.Close() })
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	cookie := adminLoginCookie(t, mux)
	time.Sleep(3 * time.Millisecond)
	if rec := serveAdminRequest(mux, http.MethodGet, PathOverview, cookie); rec.Code != http.StatusUnauthorized {
		t.Fatalf("expired session status = %d, want 401", rec.Code)
	}
	// The next login exercises Create's lazy expiry pruning directly; capacity
	// must be released even when no authenticated endpoint probes the old token.
	adminLoginCookie(t, mux)
}

func TestAdminSessionCreatePrunesExpiredCapacity(t *testing.T) {
	server := NewServerWithClient(Config{
		Address:          ":0",
		AdminUser:        "admin",
		AdminPassword:    "password-long-enough",
		AuthKey:          []byte("01234567890123456789012345678901"),
		SessionTTL:       time.Millisecond,
		MaxSessions:      1,
		LoginMaxAttempts: 5,
		LoginWindow:      time.Minute,
	}, &managementClientStub{})
	t.Cleanup(func() { _ = server.Close() })
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	adminLoginCookie(t, mux)
	time.Sleep(3 * time.Millisecond)
	// No authenticated request touches the expired token before this login.
	// memorySessionStore.Create must prune it while enforcing the one-session cap.
	adminLoginCookie(t, mux)
}
