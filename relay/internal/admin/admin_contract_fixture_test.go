package admin

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
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

type fakeRelayManagementClient struct {
	status           RelayStatus
	devices          RelayDevices
	enrollmentToken  string
	rotatedToken     string
	revokeShouldFail bool
}

func (f *fakeRelayManagementClient) Status(_ context.Context) (RelayStatus, error) {
	return f.status, nil
}

func (f *fakeRelayManagementClient) Devices(_ context.Context) (RelayDevices, error) {
	return f.devices, nil
}

func (f *fakeRelayManagementClient) RevokeDevice(_ context.Context, deviceID string) error {
	if f.revokeShouldFail || deviceID != "contract-device" {
		return ErrDeviceNotFound
	}
	return nil
}

func (f *fakeRelayManagementClient) EnrollmentToken(_ context.Context) (EnrollmentTokenInfo, error) {
	return EnrollmentTokenInfo{EnrollmentToken: f.enrollmentToken}, nil
}

func (f *fakeRelayManagementClient) RotateEnrollmentToken(_ context.Context) (EnrollmentTokenInfo, error) {
	return EnrollmentTokenInfo{EnrollmentToken: f.rotatedToken}, nil
}

// TestExportAdminAPIContractFixture exercises the standalone Admin backend handlers
// and optionally exports their JSON responses for the Front Zod contract gate.
func TestExportAdminAPIContractFixture(t *testing.T) {
	adminPassword := hex.EncodeToString(randomBytes(16))
	originalEnrollmentToken := hex.EncodeToString(randomBytes(16))
	rotatedEnrollmentToken := hex.EncodeToString(randomBytes(16))

	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(publicKey)
	fingerprint := "SHA256:" + base64.RawStdEncoding.EncodeToString(digest[:])

	fakeClient := &fakeRelayManagementClient{
		status: RelayStatus{
			ServerTime:        time.Now().Unix(),
			UptimeSeconds:     3600,
			Devices:           RelayDeviceStat{Enrolled: 1, Online: 1},
			Relay:             RelayStat{ActiveTransfers: 0},
			Runtime:           RelayRuntimeStat{AllocatedMemMB: 4.5, Goroutines: 12},
			PresenceAvailable: true,
		},
		devices: RelayDevices{
			Items: []RelayDeviceItem{
				{
					DeviceID:             "contract-device",
					Platform:             "contract-platform",
					ProtocolVersion:      2,
					EnrolledAt:           time.Now().UTC().Format(time.RFC3339Nano),
					Online:               true,
					RemoteAddr:           "198.51.100.24:43120",
					PublicKeyFingerprint: fingerprint,
				},
			},
			Total:             1,
			PresenceAvailable: true,
		},
		enrollmentToken: originalEnrollmentToken,
		rotatedToken:    rotatedEnrollmentToken,
	}

	server := NewServerWithClient(Config{
		AdminUser:     "contract-admin",
		AdminPassword: adminPassword,
		AuthKey:       []byte("01234567890123456789012345678901"),
	}, fakeClient)
	defer server.Close()

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)

	fixture := adminAPIContractFixture{
		UnauthenticatedSession: captureAdminAPIContractResponse(
			t, mux, http.MethodGet, PathAuthSession, nil, nil, http.StatusOK,
		),
		UnauthorizedOverview: captureAdminAPIContractResponse(
			t, mux, http.MethodGet, PathOverview, nil, nil, http.StatusUnauthorized,
		),
	}

	loginBody, err := json.Marshal(map[string]string{
		"username": "contract-admin",
		"password": adminPassword,
	})
	if err != nil {
		t.Fatal(err)
	}
	loginRequest := httptest.NewRequest(http.MethodPost, PathAuthLogin, bytes.NewReader(loginBody))
	loginRequest.Header.Set("Content-Type", "application/json")
	loginRecorder := httptest.NewRecorder()
	mux.ServeHTTP(loginRecorder, loginRequest)
	fixture.Login = decodeAdminAPIContractResponse(
		t,
		loginRecorder,
		http.MethodPost,
		PathAuthLogin,
		http.StatusOK,
	)
	cookies := loginRecorder.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatalf("login should return one administrator session cookie, got %d", len(cookies))
	}
	sessionCookie := cookies[0]

	fixture.AuthenticatedSession = captureAdminAPIContractResponse(
		t, mux, http.MethodGet, PathAuthSession, nil, sessionCookie, http.StatusOK,
	)

	fixture.Overview = captureAdminAPIContractResponse(
		t, mux, http.MethodGet, PathOverview, nil, sessionCookie, http.StatusOK,
	)
	fixture.Devices = captureAdminAPIContractResponse(
		t, mux, http.MethodGet, PathDevices, nil, sessionCookie, http.StatusOK,
	)

	fixture.EnrollmentToken = captureAdminAPIContractResponse(
		t, mux, http.MethodGet, PathEnrollmentToken, nil, sessionCookie, http.StatusOK,
	)
	fixture.EnrollmentToken.Body = redactAdminContractValue(
		fixture.EnrollmentToken.Body,
		originalEnrollmentToken,
	)

	fixture.RotateEnrollmentToken = captureAdminAPIContractResponse(
		t, mux, http.MethodPost, PathRotateToken, nil, sessionCookie, http.StatusOK,
	)
	fixture.RotateEnrollmentToken.Body = redactAdminContractValue(
		fixture.RotateEnrollmentToken.Body,
		rotatedEnrollmentToken,
	)

	fixture.RevokeDevice = captureAdminAPIContractResponse(
		t,
		mux,
		http.MethodPost,
		PathRevokeDevice+"contract-device/revoke",
		nil,
		sessionCookie,
		http.StatusNoContent,
	)
	fixture.Logout = captureAdminAPIContractResponse(
		t, mux, http.MethodPost, PathAuthLogout, nil, sessionCookie, http.StatusNoContent,
	)
	fixture.PostLogoutSession = captureAdminAPIContractResponse(
		t, mux, http.MethodGet, PathAuthSession, nil, sessionCookie, http.StatusOK,
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
		t.Fatalf("unexpected administrator response status on %s %s: got %d want %d (body=%s)", method, path, recorder.Code, expectedStatus, recorder.Body.String())
	}
	contentType := recorder.Header().Get("Content-Type")
	var body any
	if recorder.Body.Len() > 0 {
		if !strings.HasPrefix(contentType, "application/json") {
			t.Fatalf("administrator JSON response for %s %s used content type %q, body=%q, headers=%v", method, path, contentType, recorder.Body.String(), recorder.Header())
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
