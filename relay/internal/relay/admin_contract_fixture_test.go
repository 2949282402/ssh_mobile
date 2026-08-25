package relay

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

type adminAPIContractResponse struct {
	Method      string `json:"method"`
	Path        string `json:"path"`
	Status      int    `json:"status"`
	ContentType string `json:"content_type"`
	Body        any    `json:"body"`
}

type adminAPIContractFixture struct {
	UnauthenticatedSession adminAPIContractResponse `json:"unauthenticated_session"`
	UnauthorizedOverview   adminAPIContractResponse `json:"unauthorized_overview"`
	Login                  adminAPIContractResponse `json:"login"`
	AuthenticatedSession   adminAPIContractResponse `json:"authenticated_session"`
	Overview               adminAPIContractResponse `json:"overview"`
	Devices                adminAPIContractResponse `json:"devices"`
	EnrollmentToken        adminAPIContractResponse `json:"enrollment_token"`
	RotateEnrollmentToken  adminAPIContractResponse `json:"rotate_enrollment_token"`
	RevokeDevice           adminAPIContractResponse `json:"revoke_device"`
	Logout                 adminAPIContractResponse `json:"logout"`
	PostLogoutSession      adminAPIContractResponse `json:"post_logout_session"`
}

// TestExportAdminAPIContractFixture exercises the real registered handlers and
// optionally exports their raw JSON shapes for the Front Zod contract gate.
// Sensitive runtime values are replaced before the temporary fixture is
// written; the fixture path is supplied only by scripts/bash/contracts/admin_api_contract.sh.
func TestExportAdminAPIContractFixture(t *testing.T) {
	adminPassword := hex.EncodeToString(randomBytes(16))
	server := NewServer(Config{
		AdminUser:     "contract-admin",
		AdminPassword: adminPassword,
	})
	defer server.Close()

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	fixture := adminAPIContractFixture{
		UnauthenticatedSession: captureAdminAPIContractResponse(
			t, mux, http.MethodGet, "/api/admin/v1/auth/session", nil, nil, http.StatusOK,
		),
		UnauthorizedOverview: captureAdminAPIContractResponse(
			t, mux, http.MethodGet, "/api/admin/v1/overview", nil, nil, http.StatusUnauthorized,
		),
	}

	loginBody, err := json.Marshal(map[string]string{
		"username": "contract-admin",
		"password": adminPassword,
	})
	if err != nil {
		t.Fatal(err)
	}
	loginRequest := httptest.NewRequest(http.MethodPost, "/api/admin/v1/auth/login", bytes.NewReader(loginBody))
	loginRequest.Header.Set("Content-Type", "application/json")
	loginRecorder := httptest.NewRecorder()
	mux.ServeHTTP(loginRecorder, loginRequest)
	fixture.Login = decodeAdminAPIContractResponse(
		t,
		loginRecorder,
		http.MethodPost,
		"/api/admin/v1/auth/login",
		http.StatusOK,
	)
	cookies := loginRecorder.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatalf("login should return one administrator session cookie, got %d", len(cookies))
	}
	sessionCookie := cookies[0]

	fixture.AuthenticatedSession = captureAdminAPIContractResponse(
		t, mux, http.MethodGet, "/api/admin/v1/auth/session", nil, sessionCookie, http.StatusOK,
	)

	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if result := server.replaceEnrollment(
		"contract-device",
		base64.RawURLEncoding.EncodeToString(publicKey),
		"contract-platform",
		1,
		time.Now(),
	); result != enrollmentOK {
		t.Fatalf("contract device enrollment failed: %v", result)
	}

	fixture.Overview = captureAdminAPIContractResponse(
		t, mux, http.MethodGet, "/api/admin/v1/overview", nil, sessionCookie, http.StatusOK,
	)
	fixture.Devices = captureAdminAPIContractResponse(
		t, mux, http.MethodGet, "/api/admin/v1/devices", nil, sessionCookie, http.StatusOK,
	)

	server.tokenMutex.Lock()
	originalEnrollmentToken := server.config.EnrollmentToken
	server.tokenMutex.Unlock()
	fixture.EnrollmentToken = captureAdminAPIContractResponse(
		t, mux, http.MethodGet, "/api/admin/v1/access/enrollment-token", nil, sessionCookie, http.StatusOK,
	)
	fixture.EnrollmentToken.Body = redactAdminContractValue(
		fixture.EnrollmentToken.Body,
		originalEnrollmentToken,
	)

	fixture.RotateEnrollmentToken = captureAdminAPIContractResponse(
		t, mux, http.MethodPost, "/api/admin/v1/access/enrollment-token/rotate", nil, sessionCookie, http.StatusOK,
	)
	server.tokenMutex.Lock()
	rotatedEnrollmentToken := server.config.EnrollmentToken
	server.tokenMutex.Unlock()
	fixture.RotateEnrollmentToken.Body = redactAdminContractValue(
		fixture.RotateEnrollmentToken.Body,
		rotatedEnrollmentToken,
	)

	fixture.RevokeDevice = captureAdminAPIContractResponse(
		t,
		mux,
		http.MethodPost,
		"/api/admin/v1/devices/contract-device/revoke",
		nil,
		sessionCookie,
		http.StatusNoContent,
	)
	fixture.Logout = captureAdminAPIContractResponse(
		t, mux, http.MethodPost, "/api/admin/v1/auth/logout", nil, sessionCookie, http.StatusNoContent,
	)
	fixture.PostLogoutSession = captureAdminAPIContractResponse(
		t, mux, http.MethodGet, "/api/admin/v1/auth/session", nil, sessionCookie, http.StatusOK,
	)

	outputPath := strings.TrimSpace(os.Getenv("SSH_MOBILE_ADMIN_CONTRACT_FIXTURE"))
	if outputPath == "" {
		return
	}
	if !strings.HasPrefix(outputPath, os.TempDir()+string(os.PathSeparator)) {
		t.Fatalf("contract fixture must stay under the process temporary directory")
	}
	encoded, err := json.MarshalIndent(fixture, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	for _, sensitive := range []string{adminPassword, originalEnrollmentToken, rotatedEnrollmentToken} {
		if sensitive != "" && bytes.Contains(encoded, []byte(sensitive)) {
			t.Fatal("contract fixture retained a sensitive runtime value")
		}
	}
	if err := os.WriteFile(outputPath, append(encoded, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
}

func captureAdminAPIContractResponse(
	t *testing.T,
	mux http.Handler,
	method string,
	path string,
	body []byte,
	cookie *http.Cookie,
	expectedStatus int,
) adminAPIContractResponse {
	t.Helper()
	request := httptest.NewRequest(method, path, bytes.NewReader(body))
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if cookie != nil {
		request.AddCookie(cookie)
	}
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, request)
	return decodeAdminAPIContractResponse(t, recorder, method, path, expectedStatus)
}

func decodeAdminAPIContractResponse(
	t *testing.T,
	recorder *httptest.ResponseRecorder,
	method string,
	path string,
	expectedStatus int,
) adminAPIContractResponse {
	t.Helper()
	if recorder.Code != expectedStatus {
		t.Fatalf("unexpected administrator response status: got %d want %d", recorder.Code, expectedStatus)
	}
	contentType := recorder.Header().Get("Content-Type")
	var body any
	if recorder.Body.Len() > 0 {
		if !strings.HasPrefix(contentType, "application/json") {
			t.Fatalf("administrator JSON response used content type %q", contentType)
		}
		if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
			t.Fatalf("administrator response was not valid JSON: %v", err)
		}
	}
	return adminAPIContractResponse{
		Method:      method,
		Path:        path,
		Status:      recorder.Code,
		ContentType: contentType,
		Body:        body,
	}
}

func redactAdminContractValue(value any, sensitive string) any {
	switch current := value.(type) {
	case string:
		if current == sensitive {
			return "<redacted>"
		}
		return current
	case []any:
		for index, item := range current {
			current[index] = redactAdminContractValue(item, sensitive)
		}
		return current
	case map[string]any:
		for key, item := range current {
			current[key] = redactAdminContractValue(item, sensitive)
		}
		return current
	default:
		return current
	}
}
