//go:build online_e2e

// The online-e2e tag is intentionally opt-in. This test talks to an already
// deployed Caddy -> Admin/Relay stack and must never be selected by `go test
// ./...` or the normal CI workflow.
package online_e2e_test

import (
	"bytes"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

const (
	relayProtocolVersion = 2
	maxResponseBytes     = 4 << 20
)

type onlineHTTPClient struct {
	base string
	http *http.Client
}

type onlineResponse struct {
	status  int
	headers http.Header
	cookies []*http.Cookie
	body    []byte
}

type identity struct {
	deviceID        string
	privateKey      ed25519.PrivateKey
	publicKey       ed25519.PublicKey
	relayCredential string
	telemetrySecret string
	telemetryToken  string
}

func TestOnlineBusinessBranches(t *testing.T) {
	baseRaw := requiredEnv(t, "CLIENT_BACKEND_E2E_BASE_URL")
	enrollmentToken := requiredEnv(t, "RELAY_ENROLLMENT_TOKEN")
	adminUser := requiredEnv(t, "ONLINE_E2E_ADMIN_USER")
	adminPassword := requiredEnv(t, "ONLINE_E2E_ADMIN_PASSWORD")
	runID := requiredEnv(t, "ONLINE_E2E_RUN_ID")
	if !regexp.MustCompile(`^[A-Za-z0-9_-]{1,24}$`).MatchString(runID) {
		t.Fatalf("ONLINE_E2E_RUN_ID contains unsupported characters")
	}
	if len([]byte(runID)) > 24 {
		t.Fatalf("ONLINE_E2E_RUN_ID is too long")
	}

	baseURL, err := url.Parse(baseRaw)
	if err != nil || (baseURL.Scheme != "http" && baseURL.Scheme != "https") || baseURL.Host == "" ||
		(baseURL.Path != "" && baseURL.Path != "/") || baseURL.RawPath != "" || baseURL.RawQuery != "" || baseURL.Fragment != "" || baseURL.User != nil {
		t.Fatalf("CLIENT_BACKEND_E2E_BASE_URL must be an origin URL without a path, query, fragment, or credentials")
	}
	base := strings.TrimRight(baseRaw, "/")

	noAuth := newOnlineHTTPClient(t, base)
	admin := newOnlineHTTPClient(t, base)
	prefix := "online-e2e-" + runID + "-"
	device := newIdentity(prefix + "go-device")
	otherPublicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate conflicting identity: %v", err)
	}

	t.Run("caddy routing and unauthenticated boundaries", func(t *testing.T) {
		response := noAuth.do(t, http.MethodGet, "/", nil, nil)
		expectStatus(t, response, http.StatusOK, "Front root")
		expectHeaderContains(t, response, "Content-Type", "text/html", "Front root content type")

		response = noAuth.do(t, http.MethodGet, "/healthz", nil, nil)
		expectStatus(t, response, http.StatusNoContent, "Relay health")

		for _, path := range []string{"/v1/connect", "/internal/v2/status"} {
			response = noAuth.do(t, http.MethodGet, path, nil, nil)
			expectStatus(t, response, http.StatusNotFound, "blocked public route "+path)
		}
		for _, path := range []string{
			"/v2/control",
			"/v2/relay/00000000000000000000000000000000",
		} {
			response = noAuth.do(t, http.MethodGet, path, nil, nil)
			expectStatus(t, response, http.StatusUnauthorized, "unauthenticated Relay route "+path)
			expectHeaderContains(t, response, "Content-Type", "application/json", "Relay error content type")
		}
	})

	t.Run("relay enrollment and refresh branches", func(t *testing.T) {
		response := noAuth.do(t, http.MethodPost, "/v2/devices/enroll", []byte("{"), jsonHeaders())
		expectStatus(t, response, http.StatusBadRequest, "malformed Relay enrollment")

		response = noAuth.postJSON(t, "/v2/devices/enroll", map[string]any{
			"device_id":        prefix + "invalid-token",
			"public_key":       encodePublicKey(device.publicKey),
			"protocol_version": relayProtocolVersion,
			"enrollment_token": "online-e2e-invalid-token",
		})
		expectStatus(t, response, http.StatusUnauthorized, "invalid Relay enrollment token")

		response = noAuth.postJSON(t, "/v2/devices/enroll", map[string]any{
			"device_id":        prefix + "unsupported-version",
			"public_key":       encodePublicKey(device.publicKey),
			"protocol_version": 99,
			"enrollment_token": enrollmentToken,
		})
		expectStatus(t, response, http.StatusBadRequest, "unsupported Relay protocol version")

		response = noAuth.postJSON(t, "/v2/devices/enroll", enrollmentBody(device.deviceID, device.publicKey, enrollmentToken, relayProtocolVersion))
		expectStatus(t, response, http.StatusOK, "valid Relay enrollment")
		device.relayCredential = parseRelayCredential(t, response)

		response = noAuth.postJSON(t, "/v2/devices/enroll", enrollmentBody(device.deviceID, otherPublicKey, enrollmentToken, relayProtocolVersion))
		expectStatus(t, response, http.StatusConflict, "Relay identity conflict")

		response = noAuth.postJSON(t, "/v2/devices/enroll", enrollmentBody(device.deviceID, device.publicKey, enrollmentToken, relayProtocolVersion))
		expectStatus(t, response, http.StatusOK, "same-key Relay re-enrollment")
		device.relayCredential = parseRelayCredential(t, response)

		validRefreshBody := refreshBody(t, device, time.Now().Unix(), randomNonce())
		response = noAuth.postJSON(t, "/v2/devices/refresh", validRefreshBody)
		expectStatus(t, response, http.StatusOK, "valid Relay refresh")
		device.relayCredential = parseRelayCredential(t, response)
		response = noAuth.postJSON(t, "/v2/devices/refresh", validRefreshBody)
		expectStatus(t, response, http.StatusUnauthorized, "replayed Relay refresh proof")

		response = noAuth.postJSON(t, "/v2/devices/refresh", refreshBodyWithSignature(device, time.Now().Unix(), randomNonce(), "invalid-signature"))
		expectStatus(t, response, http.StatusUnauthorized, "invalid Relay refresh signature")
		staleTimestamp := time.Now().Add(-10 * time.Minute).Unix()
		response = noAuth.postJSON(t, "/v2/devices/refresh", refreshBody(t, device, staleTimestamp, randomNonce()))
		expectStatus(t, response, http.StatusUnauthorized, "stale Relay refresh proof")

		unknown := newIdentity(prefix + "unknown-refresh")
		response = noAuth.postJSON(t, "/v2/devices/refresh", refreshBody(t, unknown, time.Now().Unix(), randomNonce()))
		expectStatus(t, response, http.StatusNotFound, "refresh for unenrolled device")
	})

	t.Run("admin authentication and management branches", func(t *testing.T) {
		response := noAuth.do(t, http.MethodGet, "/api/admin/v1/auth/session", nil, nil)
		expectStatus(t, response, http.StatusOK, "anonymous admin session")
		anonymousSession := decodeObject(t, response, "anonymous admin session")
		if authenticated, _ := anonymousSession["authenticated"].(bool); authenticated {
			t.Fatalf("anonymous admin session was authenticated")
		}

		for _, path := range []string{
			"/api/admin/v1/overview",
			"/api/admin/v1/devices",
			"/api/admin/v1/access/enrollment-token",
		} {
			response = noAuth.do(t, http.MethodGet, path, nil, nil)
			expectStatus(t, response, http.StatusUnauthorized, "protected admin route "+path)
		}

		response = admin.do(t, http.MethodPost, "/api/admin/v1/auth/login", []byte("{"), jsonHeaders())
		expectStatus(t, response, http.StatusBadRequest, "malformed admin login")
		response = admin.postJSON(t, "/api/admin/v1/auth/login", map[string]string{
			"username": adminUser,
			"password": "online-e2e-invalid-password",
		})
		expectStatus(t, response, http.StatusUnauthorized, "invalid admin password")

		response = admin.postJSON(t, "/api/admin/v1/auth/login", map[string]string{
			"username": adminUser,
			"password": adminPassword,
		})
		expectStatus(t, response, http.StatusOK, "valid admin login")
		assertSessionCookie(t, response, baseURL.Scheme == "https")

		response = admin.do(t, http.MethodGet, "/api/admin/v1/auth/session", nil, nil)
		expectStatus(t, response, http.StatusOK, "authenticated admin session")
		session := decodeObject(t, response, "authenticated admin session")
		if authenticated, _ := session["authenticated"].(bool); !authenticated {
			t.Fatalf("valid admin session was not authenticated")
		}

		response = admin.do(t, http.MethodGet, "/api/admin/v1/overview", nil, nil)
		expectStatus(t, response, http.StatusOK, "admin overview")
		assertObjectFields(t, response, "admin overview", "server_time", "devices", "relay", "runtime")

		response = admin.do(t, http.MethodGet, "/api/admin/v1/devices", nil, nil)
		expectStatus(t, response, http.StatusOK, "admin device listing")
		assertDeviceListed(t, response, device.deviceID, true)

		response = admin.do(t, http.MethodGet, "/api/admin/v1/access/enrollment-token", nil, nil)
		expectStatus(t, response, http.StatusOK, "admin enrollment-token read")
		tokenInfo := decodeObject(t, response, "admin enrollment-token read")
		if tokenInfo["enrollment_token"] != enrollmentToken {
			t.Fatalf("admin enrollment-token read did not return the active token")
		}

		response = admin.do(t, http.MethodPost, "/api/admin/v1/devices/"+url.PathEscape(prefix+"missing")+"/revoke", nil, map[string]string{"Origin": "https://not-the-request-host.example"})
		expectStatus(t, response, http.StatusForbidden, "cross-origin admin state change")
		response = admin.do(t, http.MethodPost, "/api/admin/v1/devices/"+url.PathEscape(prefix+"missing")+"/revoke", []byte(`{"ignored":true}`), map[string]string{"Content-Type": "text/plain"})
		expectStatus(t, response, http.StatusUnsupportedMediaType, "non-JSON admin state change")
		response = admin.do(t, http.MethodPost, "/api/admin/v1/devices/"+url.PathEscape(prefix+"missing")+"/revoke", nil, nil)
		expectStatus(t, response, http.StatusNotFound, "admin revoke for unknown device")
	})

	t.Run("telemetry enrollment authentication ingestion and admin queries", func(t *testing.T) {
		response := noAuth.do(t, http.MethodGet, "/api/v1/telemetry/policy", nil, nil)
		expectStatus(t, response, http.StatusOK, "public telemetry policy")
		policy := decodeObject(t, response, "public telemetry policy")
		if _, ok := policy["policyVersion"]; !ok {
			t.Fatalf("public telemetry policy omitted policyVersion")
		}
		response = noAuth.do(t, http.MethodGet, "/api/v1/telemetry/enroll", nil, nil)
		expectStatus(t, response, http.StatusMethodNotAllowed, "wrong method for telemetry enrollment")
		response = noAuth.do(t, http.MethodPost, "/api/v1/telemetry/policy", []byte(`{}`), jsonHeaders())
		expectStatus(t, response, http.StatusMethodNotAllowed, "wrong method for telemetry policy")
		response = noAuth.postJSON(t, "/api/admin/v1/telemetry/devices", map[string]string{"deviceId": device.deviceID})
		expectStatus(t, response, http.StatusNotFound, "retired admin telemetry enrollment route")

		response = noAuth.postJSON(t, "/api/v1/telemetry/auth", map[string]any{
			"deviceId": prefix + "not-registered",
			"proof":    "invalid",
			"expEpoch": time.Now().Unix(),
		})
		expectStatus(t, response, http.StatusUnauthorized, "telemetry auth for unregistered device")

		response = noAuth.postJSON(t, "/api/v1/telemetry/enroll", telemetryEnrollmentBody(t, device, "/api/v1/telemetry/enroll", "invalid-signature"))
		expectStatus(t, response, http.StatusUnauthorized, "invalid telemetry enrollment proof")

		response = noAuth.postJSON(t, "/api/v1/telemetry/enroll", telemetryEnrollmentBody(t, device, "/api/v1/telemetry/enroll", ""))
		expectStatus(t, response, http.StatusCreated, "valid telemetry enrollment")
		device.telemetrySecret = parseTelemetrySecret(t, response)

		response = noAuth.postJSON(t, "/api/v1/telemetry/enroll", telemetryEnrollmentBody(t, device, "/api/v1/telemetry/enroll", ""))
		expectStatus(t, response, http.StatusConflict, "duplicate telemetry enrollment")

		oldSecret := device.telemetrySecret
		response = noAuth.postJSON(t, "/api/v1/telemetry/enroll/rotate", telemetryEnrollmentBody(t, device, "/api/v1/telemetry/enroll/rotate", ""))
		expectStatus(t, response, http.StatusOK, "telemetry credential rotation")
		device.telemetrySecret = parseTelemetrySecret(t, response)
		if device.telemetrySecret == oldSecret {
			t.Fatalf("telemetry credential rotation returned the old secret")
		}

		response = noAuth.postJSON(t, "/api/v1/telemetry/auth", telemetryAuthBody(t, device.deviceID, oldSecret))
		expectStatus(t, response, http.StatusUnauthorized, "telemetry auth with rotated secret")
		response = noAuth.postJSON(t, "/api/v1/telemetry/auth", telemetryAuthBody(t, device.deviceID, "invalid-telemetry-secret"))
		expectStatus(t, response, http.StatusUnauthorized, "telemetry auth with invalid proof")
		response = noAuth.postJSON(t, "/api/v1/telemetry/auth", telemetryAuthBody(t, device.deviceID, device.telemetrySecret))
		expectStatus(t, response, http.StatusOK, "telemetry auth with current secret")
		device.telemetryToken = parseTelemetryToken(t, response)

		response = noAuth.postJSON(t, "/api/v1/telemetry/ingest", map[string]any{"records": []any{}})
		expectStatus(t, response, http.StatusUnauthorized, "telemetry ingest without bearer")
		response = noAuth.do(t, http.MethodPost, "/api/v1/telemetry/ingest", []byte(`{"records":[]}`), map[string]string{
			"Authorization": "Bearer " + device.telemetryToken,
			"X-Device-Id":   prefix + "wrong-device",
			"Content-Type":  "application/json",
		})
		expectStatus(t, response, http.StatusUnauthorized, "telemetry ingest with mismatched device header")
		response = noAuth.do(t, http.MethodPost, "/api/v1/telemetry/ingest", []byte("{"), map[string]string{
			"Authorization": "Bearer " + device.telemetryToken,
			"X-Device-Id":   device.deviceID,
			"Content-Type":  "application/json",
		})
		expectStatus(t, response, http.StatusBadRequest, "malformed telemetry batch")
		response = noAuth.do(t, http.MethodGet, "/api/v1/telemetry/ingest", nil, nil)
		expectStatus(t, response, http.StatusMethodNotAllowed, "wrong method for telemetry ingest")

		response = noAuth.do(t, http.MethodPost, "/api/v1/telemetry/ingest", []byte(`{"records":[]}`), telemetryHeaders(device))
		expectStatus(t, response, http.StatusOK, "empty telemetry batch")
		if results := decodeObject(t, response, "empty telemetry batch")["results"]; results == nil {
			t.Fatalf("empty telemetry batch omitted results")
		}

		acceptedID := prefix + "accepted-event"
		rejectedID := prefix + "rejected-event"
		batch := map[string]any{"records": []any{
			telemetryEvent(device.deviceID, acceptedID, "ssh.session.started"),
			telemetryEvent(device.deviceID, rejectedID, "online.e2e.unknown"),
		}}
		response = noAuth.do(t, http.MethodPost, "/api/v1/telemetry/ingest", mustJSON(t, batch), telemetryHeaders(device))
		expectStatus(t, response, http.StatusOK, "mixed telemetry batch")
		assertIngestResult(t, response, acceptedID, "accepted")
		assertIngestResult(t, response, rejectedID, "rejected")

		response = noAuth.do(t, http.MethodPost, "/api/v1/telemetry/ingest", mustJSON(t, map[string]any{"records": []any{telemetryEvent(device.deviceID, acceptedID, "ssh.session.started")}}), telemetryHeaders(device))
		expectStatus(t, response, http.StatusOK, "duplicate telemetry event")
		assertIngestResult(t, response, acceptedID, "already_seen")

		response = noAuth.do(t, http.MethodPost, "/api/v1/telemetry/ingest", mustJSON(t, map[string]any{"records": []any{telemetryEvent(prefix+"other-device", prefix+"mismatch-event", "ssh.session.started")}}), telemetryHeaders(device))
		expectStatus(t, response, http.StatusBadRequest, "telemetry record identity mismatch")

		oversized := bytes.Repeat([]byte("x"), (1<<20)+1)
		response = noAuth.do(t, http.MethodPost, "/api/v1/telemetry/ingest", oversized, telemetryHeaders(device))
		expectStatus(t, response, http.StatusRequestEntityTooLarge, "oversized telemetry body")

		largeBatch := make([]any, 101)
		for i := range largeBatch {
			largeBatch[i] = telemetryEvent(device.deviceID, fmt.Sprintf("%s-large-%d", prefix, i), "ssh.session.started")
		}
		response = noAuth.do(t, http.MethodPost, "/api/v1/telemetry/ingest", mustJSON(t, map[string]any{"records": largeBatch}), telemetryHeaders(device))
		expectStatus(t, response, http.StatusRequestEntityTooLarge, "telemetry batch over configured limit")

		response = admin.do(t, http.MethodGet, "/api/admin/v1/telemetry/overview?timeRange=1d", nil, nil)
		expectStatus(t, response, http.StatusOK, "admin telemetry overview")
		assertObjectFields(t, response, "admin telemetry overview", "totalEvents", "eventsTrend")
		response = admin.do(t, http.MethodGet, "/api/admin/v1/telemetry/events?deviceId="+url.QueryEscape(device.deviceID)+"&eventName=ssh.session.started&pageSize=200", nil, nil)
		expectStatus(t, response, http.StatusOK, "admin telemetry events")
		assertObjectFields(t, response, "admin telemetry events", "items", "total", "page", "pageSize")
		assertEventListed(t, response, acceptedID)
		response = admin.do(t, http.MethodGet, "/api/admin/v1/telemetry/diagnostics?severity=error", nil, nil)
		expectStatus(t, response, http.StatusOK, "admin telemetry diagnostics")
		assertObjectFields(t, response, "admin telemetry diagnostics", "items", "total", "source")

		response = admin.do(t, http.MethodGet, "/api/admin/v1/telemetry/settings", nil, nil)
		expectStatus(t, response, http.StatusOK, "admin telemetry settings read")
		settings := decodeObject(t, response, "admin telemetry settings read")
		policy, ok := settings["policy"].(map[string]any)
		if !ok {
			t.Fatalf("admin telemetry settings omitted policy")
		}
		version, ok := policy["policyVersion"].(float64)
		if !ok || version < 1 {
			t.Fatalf("admin telemetry settings returned an invalid policy version")
		}
		invalidSettings := cloneObject(settings)
		invalidSettingsPolicy := invalidSettings["policy"].(map[string]any)
		invalidSettingsPolicy["policyVersion"] = 0
		response = admin.do(t, http.MethodPut, "/api/admin/v1/telemetry/settings", mustJSON(t, invalidSettings), jsonHeaders())
		expectStatus(t, response, http.StatusBadRequest, "invalid telemetry policy version")

		// Re-sending the exact snapshot is harmless. A fresh MySQL deployment may
		// have no settings row yet (200), while an initialized deployment must
		// reject the stale writer (409); both are explicit contract outcomes.
		response = admin.do(t, http.MethodPut, "/api/admin/v1/telemetry/settings", mustJSON(t, settings), jsonHeaders())
		if response.status != http.StatusOK && response.status != http.StatusConflict {
			t.Fatalf("same-version telemetry settings update returned HTTP %d", response.status)
		}
	})

	t.Run("admin revocation invalidates active business credentials", func(t *testing.T) {
		path := "/api/admin/v1/devices/" + url.PathEscape(device.deviceID) + "/revoke"
		response := admin.do(t, http.MethodPost, path, nil, nil)
		expectStatus(t, response, http.StatusNoContent, "admin device revoke")

		response = noAuth.postJSON(t, "/v2/devices/refresh", refreshBody(t, device, time.Now().Unix(), randomNonce()))
		// Revoke atomically removes the enrollment and leaves a tombstone for
		// already-issued credentials. The refresh endpoint checks enrollment
		// first, so a revoked device is intentionally reported as not enrolled.
		expectStatus(t, response, http.StatusNotFound, "refresh after Relay revoke")
		response = noAuth.postJSON(t, "/api/v1/telemetry/auth", telemetryAuthBody(t, device.deviceID, device.telemetrySecret))
		expectStatus(t, response, http.StatusUnauthorized, "telemetry auth after Relay revoke")
		response = noAuth.do(t, http.MethodPost, "/api/v1/telemetry/ingest", mustJSON(t, map[string]any{"records": []any{telemetryEvent(device.deviceID, prefix+"post-revoke", "ssh.session.started")}}), telemetryHeaders(device))
		expectStatus(t, response, http.StatusUnauthorized, "telemetry ingest after Relay revoke")

		response = admin.do(t, http.MethodPost, path, nil, nil)
		expectStatus(t, response, http.StatusNotFound, "repeated admin device revoke")
		response = admin.do(t, http.MethodGet, "/api/admin/v1/devices", nil, nil)
		expectStatus(t, response, http.StatusOK, "admin devices after revoke")
		assertDeviceListed(t, response, device.deviceID, false)

		response = admin.do(t, http.MethodPost, "/api/admin/v1/auth/logout", nil, nil)
		expectStatus(t, response, http.StatusNoContent, "admin logout")
		response = admin.do(t, http.MethodGet, "/api/admin/v1/auth/session", nil, nil)
		expectStatus(t, response, http.StatusOK, "admin session after logout")
		session := decodeObject(t, response, "admin session after logout")
		if authenticated, _ := session["authenticated"].(bool); authenticated {
			t.Fatalf("admin session remained authenticated after logout")
		}
	})
}

func requiredEnv(t *testing.T, name string) string {
	t.Helper()
	value := os.Getenv(name)
	if strings.TrimSpace(value) == "" {
		t.Fatalf("%s is required for online-e2e", name)
	}
	return value
}

func newOnlineHTTPClient(t *testing.T, base string) *onlineHTTPClient {
	t.Helper()
	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatalf("create online-e2e cookie jar: %v", err)
	}
	transport := &http.Transport{}
	caFile := strings.TrimSpace(os.Getenv("CLIENT_BACKEND_E2E_CA_FILE"))
	if caFile == "" {
		caFile = strings.TrimSpace(os.Getenv("ONLINE_E2E_CA_FILE"))
	}
	if caFile != "" {
		certificatePEM, err := os.ReadFile(caFile)
		if err != nil {
			t.Fatalf("read online-e2e CA file: %v", err)
		}
		pool, err := x509.SystemCertPool()
		if err != nil || pool == nil {
			pool = x509.NewCertPool()
		}
		if !pool.AppendCertsFromPEM(certificatePEM) {
			t.Fatalf("online-e2e CA file contains no certificate")
		}
		transport.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	}
	return &onlineHTTPClient{
		base: strings.TrimRight(base, "/"),
		http: &http.Client{
			Jar:       jar,
			Transport: transport,
			Timeout:   20 * time.Second,
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}
}

func (c *onlineHTTPClient) do(t *testing.T, method, path string, body []byte, headers map[string]string) onlineResponse {
	t.Helper()
	request, err := http.NewRequest(method, c.base+path, bytes.NewReader(body))
	if err != nil {
		t.Fatalf("create online-e2e request %s %s: %v", method, path, err)
	}
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	if body != nil && request.Header.Get("Content-Type") == "" {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := c.http.Do(request)
	if err != nil {
		t.Fatalf("online-e2e request %s %s failed: %v", method, path, err)
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes))
	if err != nil {
		t.Fatalf("read online-e2e response %s %s: %v", method, path, err)
	}
	return onlineResponse{
		status:  response.StatusCode,
		headers: response.Header.Clone(),
		cookies: response.Cookies(),
		body:    responseBody,
	}
}

func (c *onlineHTTPClient) postJSON(t *testing.T, path string, value any) onlineResponse {
	t.Helper()
	return c.do(t, http.MethodPost, path, mustJSON(t, value), jsonHeaders())
}

func jsonHeaders() map[string]string {
	return map[string]string{"Content-Type": "application/json"}
}

func expectStatus(t *testing.T, response onlineResponse, want int, operation string) {
	t.Helper()
	if response.status != want {
		t.Fatalf("%s returned HTTP %d, want %d", operation, response.status, want)
	}
}

func expectHeaderContains(t *testing.T, response onlineResponse, name, expected, operation string) {
	t.Helper()
	if !strings.Contains(strings.ToLower(response.headers.Get(name)), strings.ToLower(expected)) {
		t.Fatalf("%s header %s did not contain %q", operation, name, expected)
	}
}

func decodeObject(t *testing.T, response onlineResponse, operation string) map[string]any {
	t.Helper()
	var value map[string]any
	if err := json.Unmarshal(response.body, &value); err != nil {
		t.Fatalf("%s did not return a JSON object", operation)
	}
	return value
}

func assertObjectFields(t *testing.T, response onlineResponse, operation string, fields ...string) {
	t.Helper()
	value := decodeObject(t, response, operation)
	for _, field := range fields {
		if _, ok := value[field]; !ok {
			t.Fatalf("%s omitted JSON field %q", operation, field)
		}
	}
}

func assertSessionCookie(t *testing.T, response onlineResponse, secure bool) {
	t.Helper()
	for _, cookie := range response.cookies {
		if cookie.Name != "relay_session" || cookie.Value == "" {
			continue
		}
		if !cookie.HttpOnly {
			t.Fatalf("admin session cookie is not HttpOnly")
		}
		if secure && !cookie.Secure {
			t.Fatalf("HTTPS admin session cookie is not Secure")
		}
		return
	}
	t.Fatalf("valid admin login did not set relay_session")
}

func assertDeviceListed(t *testing.T, response onlineResponse, deviceID string, wantPresent bool) {
	t.Helper()
	value := decodeObject(t, response, "admin device listing")
	items, ok := value["items"].([]any)
	if !ok {
		t.Fatalf("admin device listing omitted items")
	}
	found := false
	for _, raw := range items {
		item, ok := raw.(map[string]any)
		if ok && item["device_id"] == deviceID {
			found = true
			break
		}
	}
	if found != wantPresent {
		t.Fatalf("device %q present=%t, want %t", deviceID, found, wantPresent)
	}
}

func assertEventListed(t *testing.T, response onlineResponse, eventID string) {
	t.Helper()
	value := decodeObject(t, response, "admin telemetry events")
	items, ok := value["items"].([]any)
	if !ok {
		t.Fatalf("admin telemetry events omitted items")
	}
	for _, raw := range items {
		item, ok := raw.(map[string]any)
		if ok && item["eventId"] == eventID {
			return
		}
	}
	t.Fatalf("admin telemetry events did not contain test event")
}

func assertIngestResult(t *testing.T, response onlineResponse, eventID, want string) {
	t.Helper()
	value := decodeObject(t, response, "telemetry ingest response")
	results, ok := value["results"].([]any)
	if !ok {
		t.Fatalf("telemetry ingest response omitted results")
	}
	for _, raw := range results {
		result, ok := raw.(map[string]any)
		if ok && result["eventId"] == eventID {
			if result["status"] != want {
				t.Fatalf("telemetry event %q status=%v, want %q", eventID, result["status"], want)
			}
			return
		}
	}
	t.Fatalf("telemetry ingest response omitted event %q", eventID)
}

func parseRelayCredential(t *testing.T, response onlineResponse) string {
	t.Helper()
	value := decodeObject(t, response, "Relay credential response")
	credential, ok := value["credential"].(string)
	if !ok || credential == "" {
		t.Fatalf("Relay credential response omitted credential")
	}
	if protocol, ok := value["protocol_version"].(float64); !ok || int(protocol) != relayProtocolVersion {
		t.Fatalf("Relay credential response used an unexpected protocol version")
	}
	if expires, ok := value["expires_at"].(float64); !ok || expires <= float64(time.Now().Unix()) {
		t.Fatalf("Relay credential response was already expired")
	}
	return credential
}

func parseTelemetrySecret(t *testing.T, response onlineResponse) string {
	t.Helper()
	value := decodeObject(t, response, "telemetry credential response")
	secret, ok := value["secret"].(string)
	if !ok || len(secret) != 64 {
		t.Fatalf("telemetry credential response omitted a 32-byte secret")
	}
	if _, err := hex.DecodeString(secret); err != nil {
		t.Fatalf("telemetry credential response secret is not hexadecimal")
	}
	return secret
}

func parseTelemetryToken(t *testing.T, response onlineResponse) string {
	t.Helper()
	value := decodeObject(t, response, "telemetry auth response")
	token, ok := value["token"].(string)
	if !ok || token == "" {
		t.Fatalf("telemetry auth response omitted token")
	}
	return token
}

func newIdentity(deviceID string) identity {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		panic(fmt.Sprintf("generate identity: %v", err))
	}
	return identity{deviceID: deviceID, privateKey: privateKey, publicKey: publicKey}
}

func enrollmentBody(deviceID string, publicKey ed25519.PublicKey, token string, protocolVersion int) map[string]any {
	return map[string]any{
		"device_id":        deviceID,
		"public_key":       encodePublicKey(publicKey),
		"protocol_version": protocolVersion,
		"platform":         "online-e2e-go",
		"enrollment_token": token,
	}
}

func refreshBody(t *testing.T, device identity, timestamp int64, nonce []byte) map[string]any {
	t.Helper()
	nonceValue := base64.RawURLEncoding.EncodeToString(nonce)
	return refreshBodyWithSignature(device, timestamp, nonce, encodeSignature(device.privateKey, "POST\n/v2/devices/refresh\n"+strconv.FormatInt(timestamp, 10)+"\n"+nonceValue))
}

func refreshBodyWithSignature(device identity, timestamp int64, nonce []byte, signature string) map[string]any {
	return map[string]any{
		"device_id":  device.deviceID,
		"public_key": encodePublicKey(device.publicKey),
		"timestamp":  timestamp,
		"nonce":      base64.RawURLEncoding.EncodeToString(nonce),
		"signature":  signature,
	}
}

func telemetryEnrollmentBody(t *testing.T, device identity, path, signatureOverride string) map[string]any {
	t.Helper()
	timestamp := time.Now().Unix()
	nonce := base64.RawURLEncoding.EncodeToString(randomNonce())
	signature := encodeSignature(device.privateKey, "POST\n"+path+"\n"+strconv.FormatInt(timestamp, 10)+"\n"+nonce)
	if signatureOverride != "" {
		signature = signatureOverride
	}
	return map[string]any{
		"deviceId":        device.deviceID,
		"relayCredential": device.relayCredential,
		"publicKey":       encodePublicKey(device.publicKey),
		"timestamp":       timestamp,
		"nonce":           nonce,
		"signature":       signature,
	}
}

func telemetryAuthBody(t *testing.T, deviceID, secret string) map[string]any {
	t.Helper()
	expires := time.Now().Unix() + 60
	derived := sha256.Sum256([]byte(secret))
	mac := hmac.New(sha256.New, []byte(hex.EncodeToString(derived[:])))
	_, _ = mac.Write([]byte("telemetry:auth:" + deviceID + ":" + strconv.FormatInt(expires, 10)))
	return map[string]any{
		"deviceId": deviceID,
		"proof":    hex.EncodeToString(mac.Sum(nil)),
		"expEpoch": expires,
	}
}

func telemetryHeaders(device identity) map[string]string {
	return map[string]string{
		"Authorization": "Bearer " + device.telemetryToken,
		"X-Device-Id":   device.deviceID,
		"Content-Type":  "application/json",
	}
}

func telemetryEvent(deviceID, eventID, eventName string) map[string]any {
	return map[string]any{
		"eventId":      eventID,
		"recordType":   "analytics",
		"eventName":    eventName,
		"eventVersion": 1,
		"deviceId":     deviceID,
		"sessionId":    eventID + "-session",
		"traceId":      eventID + "-trace",
		"occurredAt":   time.Now().UTC().Format(time.RFC3339Nano),
		"feature":      "ssh",
		"severity":     "info",
		"appVersion":   "online-e2e",
		"buildNumber":  "online-e2e",
		"platform":     "go",
		"properties": map[string]any{
			"session_type": "interactive",
			"auth_method":  "key",
		},
	}
}

func encodePublicKey(publicKey ed25519.PublicKey) string {
	return base64.RawURLEncoding.EncodeToString(publicKey)
}

func encodeSignature(privateKey ed25519.PrivateKey, transcript string) string {
	return base64.RawURLEncoding.EncodeToString(ed25519.Sign(privateKey, []byte(transcript)))
}

func randomNonce() []byte {
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		panic(fmt.Sprintf("generate nonce: %v", err))
	}
	return nonce
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	body, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("encode online-e2e JSON: %v", err)
	}
	return body
}

func cloneObject(value map[string]any) map[string]any {
	clone := make(map[string]any, len(value))
	for key, item := range value {
		if nested, ok := item.(map[string]any); ok {
			clone[key] = cloneObject(nested)
			continue
		}
		clone[key] = item
	}
	return clone
}
