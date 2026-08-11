// Docker Relay integration client for repeatable local smoke and fault tests.
// It is a test-only protocol client, not part of the Relay product or Flutter
// client.
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

type enrollment struct {
	Credential string `json:"credential"`
}

type device struct {
	id         string
	publicKey  ed25519.PublicKey
	privateKey ed25519.PrivateKey
	credential string
	conn       *websocket.Conn
}

func main() {
	base := flag.String("base", "http://localhost:18080", "Relay HTTP origin")
	scenario := flag.String("scenario", "functional", "functional, recover, restart")
	trigger := flag.String("trigger", "", "file that starts the fault phase")
	flag.Parse()

	token := os.Getenv("RELAY_ENROLLMENT_TOKEN")
	if token == "" {
		fatal("RELAY_ENROLLMENT_TOKEN is required")
	}

	switch *scenario {
	case "functional":
		runFunctional(*base, token)
	case "recover":
		runRecover(*base, token, *trigger, false)
	case "restart":
		runRecover(*base, token, *trigger, true)
	default:
		fatal("unknown scenario: %s", *scenario)
	}
}

func runFunctional(base, token string) {
	a := enroll(base, token, "docker-smoke-a")
	b := enroll(base, token, "docker-smoke-b")
	connect(base, a)
	connect(base, b)
	defer a.conn.Close()
	defer b.conn.Close()

	lookup(a, b.id)
	session := newSessionID()
	assert(sendJSON(a, map[string]any{
		"type":       "offer",
		"session_id": session,
		"target_id":  b.id,
		"payload":    base64.RawURLEncoding.EncodeToString([]byte("opaque-offer")),
	}), "offer")
	assertControl(b, "offer", session)
	assert(sendJSON(b, map[string]any{"type": "accept", "session_id": session}), "accept")
	assertControl(a, "accept", session)

	payload := []byte("docker-relay-binary-payload")
	assert(sendBinary(a, session, 0, payload), "binary")
	assertBinary(b, session, 0, payload)
	assert(sendJSON(a, map[string]any{"type": "complete", "session_id": session}), "complete")
	assertControl(b, "complete", session)
	assert(sendJSON(b, map[string]any{"type": "complete_ack", "session_id": session}), "complete_ack")
	assertControl(a, "complete_ack", session)

	fmt.Println("FUNCTIONAL_PASS enrollment=2 ready=2 lookup=online control=offer,accept,complete,complete_ack binary=exact")
}

func runRecover(base, token, trigger string, restart bool) {
	a := enroll(base, token, "docker-fault-a")
	b := enroll(base, token, "docker-fault-b")
	connect(base, a)
	connect(base, b)

	lookup(a, b.id)
	session := newSessionID()
	assert(sendJSON(a, map[string]any{
		"type":       "offer",
		"session_id": session,
		"target_id":  b.id,
		"payload":    base64.RawURLEncoding.EncodeToString([]byte("resume-offer")),
	}), "offer")
	assertControl(b, "offer", session)
	assert(sendJSON(b, map[string]any{"type": "accept", "session_id": session}), "accept")
	assertControl(a, "accept", session)
	first := []byte("chunk-before-fault")
	assert(sendBinary(a, session, 0, first), "binary-before-fault")
	assertBinary(b, session, 0, first)

	if trigger == "" {
		fatal("-trigger is required for fault scenarios")
	}
	fmt.Printf("FAULT_WINDOW_OPEN scenario=%s trigger=%s session=%s\n", map[bool]string{true: "restart", false: "recover"}[restart], filepath.Clean(trigger), session)
	waitForTrigger(trigger, 90*time.Second)

	if !waitForDisconnect(a, 20*time.Second) {
		fatal("client A did not observe the injected disconnect")
	}
	fmt.Println("CLIENT_DISCONNECTED observed=true")
	_ = b.conn.Close()

	if restart {
		waitForHealth(base, 30*time.Second)
		if connectExpectFailure(base, a) == nil {
			fatal("old credential unexpectedly survived Relay process restart")
		}
		fmt.Println("OLD_CREDENTIAL_REJECTED_AFTER_RESTART=true")
		a.credential = enrollWithKeyRetry(base, token, a, 30*time.Second)
		b.credential = enrollWithKeyRetry(base, token, b, 30*time.Second)
		fmt.Println("REENROLL_AFTER_RESTART=true")
	}

	connectWithRetry(base, a, 30*time.Second)
	connectWithRetry(base, b, 30*time.Second)
	lookup(a, b.id)
	if restart {
		// The Go Relay is intentionally memory-only. A process restart drops
		// the old session, so the client must recreate the offer/accept pair.
		session = newSessionID()
		assert(sendJSON(a, map[string]any{
			"type":       "offer",
			"session_id": session,
			"target_id":  b.id,
			"payload":    base64.RawURLEncoding.EncodeToString([]byte("recreated-offer")),
		}), "recreated-offer")
		assertControl(b, "offer", session)
		assert(sendJSON(b, map[string]any{"type": "accept", "session_id": session}), "recreated-accept")
		assertControl(a, "accept", session)
		fmt.Println("SESSION_RECREATED_AFTER_RESTART=true")
	} else {
		assert(sendJSON(b, map[string]any{"type": "resume", "session_id": session}), "resume")
		assertControl(a, "resume", session)
	}
	second := []byte("chunk-after-reconnect")
	sequence := uint64(1)
	if restart {
		sequence = 0
	}
	assert(sendBinary(a, session, sequence, second), "binary-after-reconnect")
	assertBinary(b, session, sequence, second)
	assert(sendJSON(a, map[string]any{"type": "complete", "session_id": session}), "complete")
	assertControl(b, "complete", session)
	assert(sendJSON(b, map[string]any{"type": "complete_ack", "session_id": session}), "complete_ack")
	assertControl(a, "complete_ack", session)
	_ = a.conn.Close()
	_ = b.conn.Close()

	if restart {
		fmt.Println("RESTART_RECOVERY_PASS reenroll=true reconnect=true session_recreated=true binary=exact")
	} else {
		fmt.Println("NETWORK_RECOVERY_PASS reconnect=true resume=true binary=exact")
	}
}

func enroll(base, token, id string) *device {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		fatal("generate key %s: %v", id, err)
	}
	d := &device{id: id, publicKey: publicKey, privateKey: privateKey}
	d.credential = enrollWithKey(base, token, d)
	fmt.Printf("ENROLL_OK device=%s\n", id)
	return d
}

func enrollWithKey(base, token string, d *device) string {
	credential, err := requestEnrollment(base, token, d)
	if err != nil {
		fatal("enrollment: %v", err)
	}
	return credential
}

func enrollWithKeyRetry(base, token string, d *device, timeout time.Duration) string {
	deadline := time.Now().Add(timeout)
	var lastError error
	for time.Now().Before(deadline) {
		credential, err := requestEnrollment(base, token, d)
		if err == nil {
			return credential
		}
		lastError = err
		time.Sleep(500 * time.Millisecond)
	}
	fatal("enrollment retry timeout device=%s: %v", d.id, lastError)
	return ""
}

func requestEnrollment(base, token string, d *device) (string, error) {
	payload, err := json.Marshal(map[string]any{
		"device_id":        d.id,
		"public_key":       base64.RawURLEncoding.EncodeToString(d.publicKey),
		"enrollment_token": token,
		"protocol_version": 1,
		"platform":         "docker-smoke",
	})
	if err != nil {
		return "", fmt.Errorf("encode request: %w", err)
	}
	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(base, "/")+"/v1/devices/enroll", strings.NewReader(string(payload)))
	if err != nil {
		return "", fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Connection", "close")
	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		return "", fmt.Errorf("request: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var response enrollment
	if err := json.Unmarshal(body, &response); err != nil || response.Credential == "" {
		return "", fmt.Errorf("invalid response: %s", strings.TrimSpace(string(body)))
	}
	return response.Credential, nil
}

func connect(base string, d *device) {
	if d.conn != nil {
		_ = d.conn.Close()
	}
	u, err := url.Parse(strings.TrimRight(base, "/"))
	if err != nil {
		fatal("parse relay URL: %v", err)
	}
	if u.Scheme == "http" {
		u.Scheme = "ws"
	} else if u.Scheme == "https" {
		u.Scheme = "wss"
	} else {
		fatal("unsupported relay scheme: %s", u.Scheme)
	}
	u.Path = "/v1/connect"
	nonceBytes := make([]byte, 32)
	if _, err := rand.Read(nonceBytes); err != nil {
		fatal("generate proof nonce: %v", err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(nonceBytes)
	signature := ed25519.Sign(d.privateKey, []byte("GET\n/v1/connect\n"+nonce))
	headers := http.Header{}
	headers.Set("Authorization", "Bearer "+d.credential)
	headers.Set("X-Relay-Nonce", nonce)
	headers.Set("X-Relay-Signature", base64.RawURLEncoding.EncodeToString(signature))
	conn, response, err := websocket.DefaultDialer.Dial(u.String(), headers)
	if err != nil {
		status := 0
		if response != nil {
			status = response.StatusCode
		}
		fatal("connect device=%s status=%d: %v", d.id, status, err)
	}
	d.conn = conn
	conn.SetReadDeadline(time.Now().Add(8 * time.Second))
	_, message, err := conn.ReadMessage()
	if err != nil {
		fatal("ready device=%s: %v", d.id, err)
	}
	var ready map[string]any
	if json.Unmarshal(message, &ready) != nil || ready["type"] != "ready" || ready["device_id"] != d.id || int(ready["protocol_version"].(float64)) != 1 {
		fatal("invalid ready device=%s: %s", d.id, string(message))
	}
	conn.SetReadDeadline(time.Time{})
	fmt.Printf("READY device=%s\n", d.id)
}

func connectExpectFailure(base string, d *device) error {
	if d.conn != nil {
		_ = d.conn.Close()
		d.conn = nil
	}
	u, err := url.Parse(strings.TrimRight(base, "/"))
	if err != nil {
		return err
	}
	u.Scheme = map[string]string{"http": "ws", "https": "wss"}[u.Scheme]
	u.Path = "/v1/connect"
	nonceBytes := make([]byte, 32)
	if _, err := rand.Read(nonceBytes); err != nil {
		return err
	}
	nonce := base64.RawURLEncoding.EncodeToString(nonceBytes)
	headers := http.Header{}
	headers.Set("Authorization", "Bearer "+d.credential)
	headers.Set("X-Relay-Nonce", nonce)
	headers.Set("X-Relay-Signature", base64.RawURLEncoding.EncodeToString(ed25519.Sign(d.privateKey, []byte("GET\n/v1/connect\n"+nonce))))
	_, response, err := websocket.DefaultDialer.Dial(u.String(), headers)
	status := 0
	if response != nil {
		status = response.StatusCode
	}
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err == nil {
		return errors.New("unexpected successful connection")
	}
	if status != http.StatusUnauthorized {
		return fmt.Errorf("expected HTTP 401 from Relay, got %d: %w", status, err)
	}
	return err
}

func connectWithRetry(base string, d *device, timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	attempts := 0
	for time.Now().Before(deadline) {
		attempts++
		if err := tryConnect(base, d); err == nil {
			fmt.Printf("RECONNECT_OK device=%s attempts=%d\n", d.id, attempts)
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
	fatal("reconnect timeout device=%s", d.id)
}

func tryConnect(base string, d *device) error {
	if d.conn != nil {
		_ = d.conn.Close()
		d.conn = nil
	}
	u, err := url.Parse(strings.TrimRight(base, "/"))
	if err != nil {
		return err
	}
	u.Scheme = map[string]string{"http": "ws", "https": "wss"}[u.Scheme]
	u.Path = "/v1/connect"
	nonceBytes := make([]byte, 32)
	if _, err := rand.Read(nonceBytes); err != nil {
		return err
	}
	nonce := base64.RawURLEncoding.EncodeToString(nonceBytes)
	headers := http.Header{}
	headers.Set("Authorization", "Bearer "+d.credential)
	headers.Set("X-Relay-Nonce", nonce)
	headers.Set("X-Relay-Signature", base64.RawURLEncoding.EncodeToString(ed25519.Sign(d.privateKey, []byte("GET\n/v1/connect\n"+nonce))))
	conn, response, err := websocket.DefaultDialer.Dial(u.String(), headers)
	if err != nil {
		if response != nil && response.Body != nil {
			_ = response.Body.Close()
		}
		return err
	}
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, message, err := conn.ReadMessage()
	if err != nil {
		_ = conn.Close()
		return err
	}
	var ready map[string]any
	if err := json.Unmarshal(message, &ready); err != nil || ready["type"] != "ready" || ready["device_id"] != d.id {
		_ = conn.Close()
		return errors.New("invalid ready")
	}
	conn.SetReadDeadline(time.Time{})
	d.conn = conn
	return nil
}

func lookup(d *device, target string) {
	assert(sendJSON(d, map[string]any{"type": "lookup", "target_id": target}), "lookup")
	_, message, err := readMessage(d, 8*time.Second)
	if err != nil {
		fatal("lookup response: %v", err)
	}
	var response map[string]any
	if json.Unmarshal(message, &response) != nil || response["type"] != "lookup_response" || response["target_id"] != target || response["online"] != true {
		fatal("lookup response invalid: %s", string(message))
	}
	fmt.Printf("LOOKUP_OK target=%s online=true\n", target)
}

func assertControl(d *device, kind, session string) {
	_, message, err := readMessage(d, 8*time.Second)
	if err != nil {
		fatal("control %s: %v", kind, err)
	}
	var value map[string]any
	if json.Unmarshal(message, &value) != nil || value["type"] != kind || value["session_id"] != session {
		fatal("control %s invalid: %s", kind, string(message))
	}
	fmt.Printf("CONTROL_OK device=%s type=%s\n", d.id, kind)
}

func assertBinary(d *device, session string, sequence uint64, expected []byte) {
	_, frame, err := readMessage(d, 8*time.Second)
	if err != nil {
		fatal("binary seq=%d: %v", sequence, err)
	}
	if len(frame) != 25+len(expected) || frame[0] != 0x10 || hex.EncodeToString(frame[1:17]) != session || binary.BigEndian.Uint64(frame[17:25]) != sequence || string(frame[25:]) != string(expected) {
		fatal("binary frame mismatch seq=%d len=%d", sequence, len(frame))
	}
	fmt.Printf("BINARY_OK device=%s sequence=%d bytes=%d\n", d.id, sequence, len(expected))
}

func sendJSON(d *device, value map[string]any) error {
	d.conn.SetWriteDeadline(time.Now().Add(8 * time.Second))
	return d.conn.WriteJSON(value)
}

func sendBinary(d *device, session string, sequence uint64, payload []byte) error {
	id, err := hex.DecodeString(session)
	if err != nil || len(id) != 16 {
		return errors.New("invalid session")
	}
	frame := make([]byte, 25+len(payload))
	frame[0] = 0x10
	copy(frame[1:17], id)
	binary.BigEndian.PutUint64(frame[17:25], sequence)
	copy(frame[25:], payload)
	d.conn.SetWriteDeadline(time.Now().Add(8 * time.Second))
	return d.conn.WriteMessage(websocket.BinaryMessage, frame)
}

func readMessage(d *device, timeout time.Duration) (int, []byte, error) {
	d.conn.SetReadDeadline(time.Now().Add(timeout))
	kind, message, err := d.conn.ReadMessage()
	d.conn.SetReadDeadline(time.Time{})
	return kind, message, err
}

func waitForDisconnect(d *device, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		d.conn.SetReadDeadline(time.Now().Add(1 * time.Second))
		_, _, err := d.conn.ReadMessage()
		if err != nil {
			_ = d.conn.Close()
			d.conn = nil
			return true
		}
	}
	return false
}

func waitForTrigger(path string, timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(250 * time.Millisecond)
	}
	fatal("fault trigger timeout: %s", path)
}

func waitForHealth(base string, timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	client := &http.Client{Timeout: 2 * time.Second}
	for time.Now().Before(deadline) {
		request, err := http.NewRequest(http.MethodGet, strings.TrimRight(base, "/")+"/healthz", nil)
		if err == nil {
			request.Header.Set("Connection", "close")
			response, requestError := client.Do(request)
			if requestError == nil {
				_, _ = io.Copy(io.Discard, response.Body)
				_ = response.Body.Close()
				if response.StatusCode == http.StatusNoContent || response.StatusCode == http.StatusOK {
					return
				}
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	fatal("Relay health did not recover within %s", timeout)
}

func newSessionID() string {
	bytes := make([]byte, 16)
	if _, err := rand.Read(bytes); err != nil {
		fatal("generate session ID: %v", err)
	}
	return hex.EncodeToString(bytes)
}

func assert(err error, operation string) {
	if err != nil {
		fatal("%s: %v", operation, err)
	}
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "SMOKE_FAIL "+format+"\n", args...)
	os.Exit(1)
}
