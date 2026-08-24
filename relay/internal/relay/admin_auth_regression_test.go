package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type adminSessionContextKey struct{}

type adminSessionCacheProbe struct {
	Cache
	setContext    context.Context
	existsContext context.Context
	deleteContext context.Context
	exists        bool
	setErr        error
	deleteErr     error
}

func (p *adminSessionCacheProbe) SetAdminSession(ctx context.Context, _ string, _ time.Duration) error {
	p.setContext = ctx
	return p.setErr
}

func TestAdminLoginDistinguishesCapacityFromSessionStoreFailure(t *testing.T) {
	for _, test := range []struct {
		name       string
		setErr     error
		statusCode int
		errorCode  string
	}{
		{
			name:       "capacity",
			setErr:     errAdminSessionCapacity,
			statusCode: http.StatusTooManyRequests,
			errorCode:  adminErrorResourceLimit,
		},
		{
			name:       "store unavailable",
			setErr:     errors.New("cache unavailable: internal detail"),
			statusCode: http.StatusServiceUnavailable,
			errorCode:  adminErrorInternal,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, mux, probe := newAdminSessionContextTestServer(t)
			probe.setErr = test.setErr
			body := bytes.NewBufferString(`{"username":"test-admin","password":"test-password-123"}`)
			request := httptest.NewRequest(http.MethodPost, "/api/admin/v1/auth/login", body)
			request.Header.Set("Content-Type", "application/json")
			response := httptest.NewRecorder()

			mux.ServeHTTP(response, request)

			if response.Code != test.statusCode {
				t.Fatalf("login status=%d want=%d body=%s", response.Code, test.statusCode, response.Body.String())
			}
			var failure adminErrorResponse
			if err := json.NewDecoder(response.Body).Decode(&failure); err != nil {
				t.Fatalf("decode login error: %v", err)
			}
			if failure.Error.Code != test.errorCode {
				t.Fatalf("login error code=%q want=%q", failure.Error.Code, test.errorCode)
			}
			if strings.Contains(failure.Error.Message, "internal detail") {
				t.Fatalf("login leaked storage detail: %+v", failure)
			}
		})
	}
}

func (p *adminSessionCacheProbe) AdminSessionExists(ctx context.Context, _ string) (bool, error) {
	p.existsContext = ctx
	return p.exists, nil
}

func (p *adminSessionCacheProbe) DeleteAdminSession(ctx context.Context, _ string) error {
	p.deleteContext = ctx
	return p.deleteErr
}

func newAdminSessionContextTestServer(t *testing.T) (*Server, *http.ServeMux, *adminSessionCacheProbe) {
	t.Helper()
	server := NewServer(Config{
		CredentialKey:   []byte("01234567890123456789012345678901"),
		EnrollmentToken: "test-enrollment-token",
		AdminUser:       "test-admin",
		AdminPassword:   "test-password-123",
	})
	probe := &adminSessionCacheProbe{Cache: server.cache}
	server.cache = probe
	t.Cleanup(server.Close)
	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	return server, mux, probe
}

func TestAdminSessionStorageCallsUseRequestContext(t *testing.T) {
	t.Run("login creates session with request context", func(t *testing.T) {
		_, mux, probe := newAdminSessionContextTestServer(t)
		body := bytes.NewBufferString(`{"username":"test-admin","password":"test-password-123"}`)
		request := httptest.NewRequest(http.MethodPost, "/api/admin/v1/auth/login", body)
		request.Header.Set("Content-Type", "application/json")
		request = request.WithContext(context.WithValue(request.Context(), adminSessionContextKey{}, "login"))
		response := httptest.NewRecorder()

		mux.ServeHTTP(response, request)

		if response.Code != http.StatusOK {
			t.Fatalf("login status=%d body=%s", response.Code, response.Body.String())
		}
		if probe.setContext == nil || probe.setContext.Value(adminSessionContextKey{}) != "login" {
			t.Fatal("SetAdminSession did not receive the login request context")
		}
		if _, ok := probe.setContext.Deadline(); !ok {
			t.Fatal("SetAdminSession context has no bounded deadline")
		}
	})

	t.Run("session lookup uses request context", func(t *testing.T) {
		_, mux, probe := newAdminSessionContextTestServer(t)
		probe.exists = true
		request := httptest.NewRequest(http.MethodGet, "/api/admin/v1/auth/session", nil)
		request.AddCookie(&http.Cookie{Name: "relay_session", Value: "session-token"})
		request = request.WithContext(context.WithValue(request.Context(), adminSessionContextKey{}, "session"))
		response := httptest.NewRecorder()

		mux.ServeHTTP(response, request)

		if response.Code != http.StatusOK {
			t.Fatalf("session status=%d body=%s", response.Code, response.Body.String())
		}
		if probe.existsContext == nil || probe.existsContext.Value(adminSessionContextKey{}) != "session" {
			t.Fatal("AdminSessionExists did not receive the session request context")
		}
		if _, ok := probe.existsContext.Deadline(); !ok {
			t.Fatal("AdminSessionExists context has no bounded deadline")
		}
	})

	t.Run("logout deletes session with request context", func(t *testing.T) {
		_, mux, probe := newAdminSessionContextTestServer(t)
		request := httptest.NewRequest(http.MethodPost, "/api/admin/v1/auth/logout", nil)
		request.AddCookie(&http.Cookie{Name: "relay_session", Value: "session-token"})
		request = request.WithContext(context.WithValue(request.Context(), adminSessionContextKey{}, "logout"))
		response := httptest.NewRecorder()

		mux.ServeHTTP(response, request)

		if response.Code != http.StatusNoContent {
			t.Fatalf("logout status=%d body=%s", response.Code, response.Body.String())
		}
		if probe.deleteContext == nil || probe.deleteContext.Value(adminSessionContextKey{}) != "logout" {
			t.Fatal("DeleteAdminSession did not receive the logout request context")
		}
		if _, ok := probe.deleteContext.Deadline(); !ok {
			t.Fatal("DeleteAdminSession context has no bounded deadline")
		}
	})
}

func TestAdminLogoutClearsCookieWhenSessionDeletionFails(t *testing.T) {
	_, mux, probe := newAdminSessionContextTestServer(t)
	probe.deleteErr = errors.New("cache unavailable: internal detail")
	request := httptest.NewRequest(http.MethodPost, "/api/admin/v1/auth/logout", nil)
	request.AddCookie(&http.Cookie{Name: "relay_session", Value: "session-token"})
	response := httptest.NewRecorder()

	mux.ServeHTTP(response, request)

	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("logout status=%d, want %d; body=%s", response.Code, http.StatusServiceUnavailable, response.Body.String())
	}
	var failure adminErrorResponse
	if err := json.NewDecoder(response.Body).Decode(&failure); err != nil {
		t.Fatalf("decode logout error: %v", err)
	}
	if failure.Error.Code != adminErrorInternal || failure.Error.Message != "Administrator session store is unavailable." {
		t.Fatalf("unexpected logout error: %+v", failure)
	}
	cookies := response.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Name != "relay_session" || cookies[0].Value != "" || cookies[0].MaxAge >= 0 {
		t.Fatalf("logout did not clear browser cookie after cache failure: %+v", cookies)
	}
}
