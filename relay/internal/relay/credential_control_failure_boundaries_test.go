package relay

import (
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

func TestCredentialVerificationFailureBoundaries(t *testing.T) {
	key := []byte(mysqlTestCredentialKey)
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	signPayload := func(payload []byte) string {
		mac := hmac.New(sha256.New, key)
		_, _ = mac.Write(payload)
		return base64.RawURLEncoding.EncodeToString(payload) + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	}
	claimsToken := func(claims credentialClaims) string {
		payload, err := json.Marshal(claims)
		if err != nil {
			t.Fatal(err)
		}
		return signPayload(payload)
	}
	valid := claimsToken(credentialClaims{
		DeviceID:  "device-a",
		PublicKey: base64.RawURLEncoding.EncodeToString(publicKey),
		ExpiresAt: time.Now().Add(time.Hour).Unix(),
	})
	invalidJSON := signPayload([]byte("{"))
	missingDevice := claimsToken(credentialClaims{
		PublicKey: base64.RawURLEncoding.EncodeToString(publicKey),
		ExpiresAt: time.Now().Add(time.Hour).Unix(),
	})
	expired := claimsToken(credentialClaims{
		DeviceID:  "device-a",
		PublicKey: base64.RawURLEncoding.EncodeToString(publicKey),
		ExpiresAt: time.Now().Add(-time.Hour).Unix(),
	})
	badPublicKey := claimsToken(credentialClaims{
		DeviceID:  "device-a",
		PublicKey: "not-a-key",
		ExpiresAt: time.Now().Add(time.Hour).Unix(),
	})

	tests := []struct {
		name  string
		token string
		want  error
	}{
		{name: "missing separator", token: "one-part"},
		{name: "invalid payload encoding", token: "%%%.abc"},
		{name: "invalid signature encoding", token: base64.RawURLEncoding.EncodeToString([]byte("{}")) + ".%%%"},
		{name: "signature mismatch", token: base64.RawURLEncoding.EncodeToString([]byte("{}")) + "." + base64.RawURLEncoding.EncodeToString([]byte("bad"))},
		{name: "invalid json", token: invalidJSON},
		{name: "missing device id", token: missingDevice},
		{name: "expired", token: expired, want: errCredentialExpired},
		{name: "invalid public key", token: badPublicKey},
		{name: "valid", token: valid},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			claims, restored, err := verifyCredential(key, test.token)
			if test.name == "valid" {
				if err != nil || claims.DeviceID != "device-a" || !hmac.Equal(restored, publicKey) {
					t.Fatalf("valid credential rejected: claims=%+v key=%d err=%v", claims, len(restored), err)
				}
				return
			}
			if err == nil {
				t.Fatalf("invalid credential was accepted: claims=%+v", claims)
			}
			if test.want != nil && !errors.Is(err, test.want) {
				t.Fatalf("error=%v, want %v", err, test.want)
			}
		})
	}
}

func TestDeviceProofFailureBoundaries(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	payload := "GET\n/v2/control\nnonce"
	validSignature := base64.RawURLEncoding.EncodeToString(ed25519.Sign(privateKey, []byte(payload)))
	for _, test := range []struct {
		name, payload, signature string
		wantErr                  bool
	}{
		{name: "valid", payload: payload, signature: validSignature},
		{name: "bad encoding", payload: payload, signature: "%%%", wantErr: true},
		{name: "empty payload", payload: "", signature: validSignature, wantErr: true},
		{name: "wrong signature", payload: payload, signature: base64.RawURLEncoding.EncodeToString([]byte("bad")), wantErr: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := verifyDeviceProof(publicKey, test.payload, test.signature)
			if (err != nil) != test.wantErr {
				t.Fatalf("verifyDeviceProof error=%v, wantErr=%v", err, test.wantErr)
			}
		})
	}
}

func TestConfigParsingAndEndpointFallbackBoundaries(t *testing.T) {
	setValid := func(t *testing.T) {
		t.Helper()
		t.Setenv("RELAY_ENROLLMENT_TOKEN", "0123456789abcdef")
		t.Setenv("RELAY_CREDENTIAL_KEY", "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE")
		t.Setenv("RELAY_ADMIN_USER", "admin")
		t.Setenv("RELAY_ADMIN_PASSWORD", "long-random-password")
		t.Setenv("RELAY_STORAGE_MODE", "memory")
	}

	setValid(t)
	t.Setenv("RELAY_ENROLLMENT_TOKEN", "")
	if _, err := ConfigFromEnvironment(); err == nil {
		t.Fatal("missing enrollment token was accepted")
	}
	setValid(t)
	t.Setenv("RELAY_CREDENTIAL_KEY", "not-base64")
	if _, err := ConfigFromEnvironment(); err == nil {
		t.Fatal("malformed credential key was accepted")
	}
	setValid(t)
	t.Setenv("RELAY_CREDENTIAL_KEY", base64.RawURLEncoding.EncodeToString([]byte("short")))
	if _, err := ConfigFromEnvironment(); err == nil {
		t.Fatal("short credential key was accepted")
	}

	t.Setenv("RELAY_DURATION_BOUNDARY", "not-a-duration")
	if got := durationEnv("RELAY_DURATION_BOUNDARY", 7*time.Second); got != 7*time.Second {
		t.Fatalf("invalid duration did not fall back: %s", got)
	}
	t.Setenv("RELAY_DURATION_BOUNDARY", "0s")
	if got := durationEnv("RELAY_DURATION_BOUNDARY", 7*time.Second); got != 7*time.Second {
		t.Fatalf("non-positive duration did not fall back: %s", got)
	}
	t.Setenv("RELAY_INT_BOUNDARY", "not-an-int")
	if got := intEnv("RELAY_INT_BOUNDARY", 9); got != 9 {
		t.Fatalf("invalid int did not fall back: %d", got)
	}
	t.Setenv("RELAY_INT64_BOUNDARY", "0")
	if got := int64Env("RELAY_INT64_BOUNDARY", 11); got != 11 {
		t.Fatalf("non-positive int64 did not fall back: %d", got)
	}

	for _, test := range []struct {
		address, want string
	}{
		{address: "not-a-listen-address", want: "wss://localhost:not-a-listen-address"},
	} {
		if got := relayDataEndpointOrigin(Config{Address: test.address}); got != test.want {
			t.Errorf("relayDataEndpointOrigin(%q)=%q, want %q", test.address, got, test.want)
		}
	}
}

func TestAdminLoginLimitEvictsOldestAndBlocks(t *testing.T) {
	server := NewServer(Config{
		CredentialKey:           []byte(mysqlTestCredentialKey),
		EnrollmentToken:         "test-token",
		MaxAdminLoginEntries:    2,
		AdminLoginMaxAttempts:   1,
		AdminLoginWindow:        time.Minute,
		AdminLoginBlockDuration: time.Minute,
	})
	defer server.Close()
	old := time.Now().Add(-5 * time.Second)
	server.admin.mutex.Lock()
	server.admin.loginAttempts = map[string]adminLoginAttempt{
		"old\x00user": {windowStartedAt: old, lastSeen: old},
		"new\x00user": {windowStartedAt: old.Add(time.Second), lastSeen: old.Add(time.Second)},
	}
	server.admin.mutex.Unlock()
	if allowed, _ := server.allowAdminLogin("client", "fresh"); !allowed {
		t.Fatal("fresh login should be admitted after evicting the oldest entry")
	}
	server.admin.mutex.Lock()
	_, oldPresent := server.admin.loginAttempts["old\x00user"]
	_, freshPresent := server.admin.loginAttempts["client\x00fresh"]
	server.admin.mutex.Unlock()
	if oldPresent || !freshPresent {
		t.Fatalf("login limiter eviction state: oldPresent=%v freshPresent=%v", oldPresent, freshPresent)
	}
	if allowed, retry := server.allowAdminLogin("client", "fresh"); allowed || retry <= 0 {
		t.Fatalf("second attempt should be blocked: allowed=%v retry=%s", allowed, retry)
	}
	server.clearAdminLoginLimit("client", "fresh")
}

func TestAdminRevokeDeviceRequestBoundaries(t *testing.T) {
	server := NewServer(Config{CredentialKey: []byte(mysqlTestCredentialKey), EnrollmentToken: "test-token"})
	defer server.Close()
	for name, request := range map[string]*http.Request{
		"missing": httptest.NewRequest(http.MethodPost, "/api/admin/v1/devices//revoke", nil),
		"too long": func() *http.Request {
			r := httptest.NewRequest(http.MethodPost, "/api/admin/v1/devices/revoke", nil)
			r.SetPathValue("deviceId", string(make([]byte, 129)))
			return r
		}(),
	} {
		t.Run(name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			server.adminRevokeDevice(rec, request)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("invalid revoke request status=%d body=%s", rec.Code, rec.Body.String())
			}
		})
	}
	request := httptest.NewRequest(http.MethodPost, "/api/admin/v1/devices/missing/revoke", nil)
	request.SetPathValue("deviceId", "missing")
	rec := httptest.NewRecorder()
	server.adminRevokeDevice(rec, request)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("unknown device revoke status=%d body=%s", rec.Code, rec.Body.String())
	}
}

type boundaryRenewPresenceFailure struct {
	Cache
}

func (boundaryRenewPresenceFailure) RenewPresence(context.Context, string, string, Presence, time.Duration) (bool, error) {
	return false, errors.New("presence renewal unavailable")
}

type boundaryRenewDiscoveryFailure struct {
	Cache
}

func (boundaryRenewDiscoveryFailure) RenewDiscovery(context.Context, string, string, time.Duration) (bool, error) {
	return false, errors.New("discovery renewal unavailable")
}

type boundaryRenewPresenceRemovesPeer struct {
	Cache
	hub *hub
}

func (b boundaryRenewPresenceRemovesPeer) RenewPresence(ctx context.Context, deviceID, connID string, p Presence, ttl time.Duration) (bool, error) {
	ok, err := b.Cache.RenewPresence(ctx, deviceID, connID, p, ttl)
	b.hub.mutex.Lock()
	delete(b.hub.peers, deviceID)
	b.hub.mutex.Unlock()
	return ok, err
}

func boundaryHeartbeatPeer(deviceID string) *peer {
	return &peer{
		deviceID:         deviceID,
		connectionID:     "conn-" + deviceID,
		outbound:         make(chan outboundFrame, 8),
		done:             make(chan struct{}),
		maxPendingFrames: 8,
		maxPendingBytes:  4096,
	}
}

func boundaryReadProtocolError(t *testing.T, p *peer) *v2.ProtocolError {
	t.Helper()
	frame := readV2ControlFrameFromPeer(t, p)
	if frame.GetProtocolError() == nil {
		t.Fatalf("expected protocol error, got %s", v2.KindName(frame))
	}
	return frame.GetProtocolError()
}

func TestHeartbeatLeaseFailureBoundaries(t *testing.T) {
	for name, cache := range map[string]Cache{
		"presence renewal":  boundaryRenewPresenceFailure{Cache: newMemoryStore(Config{})},
		"discovery renewal": boundaryRenewDiscoveryFailure{Cache: newMemoryStore(Config{})},
	} {
		t.Run(name, func(t *testing.T) {
			store := newMemoryStore(Config{})
			sender := boundaryHeartbeatPeer("heartbeat-" + name)
			if name == "discovery renewal" {
				cache = boundaryRenewDiscoveryFailure{Cache: store}
				if _, _, err := store.TakePresence(context.Background(), sender.deviceID, sender.connectionID, Presence{}, time.Minute); err != nil {
					t.Fatal(err)
				}
			} else {
				cache = boundaryRenewPresenceFailure{Cache: store}
			}
			h := &hub{peers: map[string]*peer{sender.deviceID: sender}, presence: cache, presenceTTL: time.Minute}
			h.handleHeartbeatV2(sender, &v2.Heartbeat{RequestId: 17})
			got := boundaryReadProtocolError(t, sender)
			if got.RequestId != 17 || got.Code != v2.ErrorCode_ERROR_CODE_CONTROL_UNAVAILABLE {
				t.Fatalf("heartbeat lease error=%+v", got)
			}
		})
	}
}

func TestHeartbeatCurrencyRecheckReleasesLease(t *testing.T) {
	store := newMemoryStore(Config{})
	sender := boundaryHeartbeatPeer("heartbeat-currency")
	h := &hub{peers: map[string]*peer{sender.deviceID: sender}, presenceTTL: time.Minute}
	h.presence = boundaryRenewPresenceRemovesPeer{Cache: store, hub: h}
	if _, _, err := store.TakePresence(context.Background(), sender.deviceID, sender.connectionID, Presence{}, time.Minute); err != nil {
		t.Fatal(err)
	}
	h.handleHeartbeatV2(sender, &v2.Heartbeat{RequestId: 18})
	select {
	case <-sender.done:
	default:
		t.Fatal("peer was not closed after currency changed")
	}
	if _, present, err := store.GetPresence(context.Background(), sender.deviceID); err != nil || present {
		t.Fatalf("stale lease was not released: present=%v err=%v", present, err)
	}
}

func TestControlLeaseCurrentBoundaries(t *testing.T) {
	peer := boundaryHeartbeatPeer("lease")
	h := &hub{}
	if h.controlLeaseCurrentV2(peer) {
		t.Fatal("nil presence store reported a current lease")
	}
	store := newMemoryStore(Config{})
	h.presence = store
	if h.controlLeaseCurrentV2(nil) {
		t.Fatal("nil peer reported a current lease")
	}
	if h.controlLeaseCurrentV2(peer) {
		t.Fatal("missing lease reported as current")
	}
	if _, _, err := store.TakePresence(context.Background(), peer.deviceID, "foreign", Presence{}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if h.controlLeaseCurrentV2(peer) {
		t.Fatal("foreign lease reported as current")
	}
	if _, _, err := store.TakePresence(context.Background(), peer.deviceID, peer.connectionID, Presence{}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if !h.controlLeaseCurrentV2(peer) {
		t.Fatal("matching lease was not reported as current")
	}
}

func TestConnectivityAnswerRoutingFailureBoundaries(t *testing.T) {
	makePeer := func(deviceID, connectionID string) *peer {
		p := boundaryHeartbeatPeer(deviceID)
		p.connectionID = connectionID
		return p
	}
	initiator := makePeer("initiator", "initiator-1")
	target := makePeer("target", "target-1")
	wrong := makePeer("wrong", "wrong-1")
	h := &hub{
		peers:      map[string]*peer{initiator.deviceID: initiator, target.deviceID: target, wrong.deviceID: wrong},
		v2Attempts: map[string]v2Attempt{},
	}
	h.v2Attempts["live"] = v2Attempt{
		initiator:             initiator.deviceID,
		initiatorConnectionID: initiator.connectionID,
		target:                target.deviceID,
		targetConnectionID:    target.connectionID,
		expiresAt:             time.Now().Add(time.Minute),
	}
	h.handleConnectivityAnswerV2(wrong, &v2.ConnectivityAnswer{AttemptId: "live", RequestId: 1})
	if _, ok := h.v2Attempts["live"]; !ok {
		t.Fatal("mismatched answer consumed a live attempt")
	}
	select {
	case frame := <-initiator.outbound:
		t.Fatalf("mismatched answer was routed: %+v", frame)
	default:
	}

	h.handleConnectivityAnswerV2(target, &v2.ConnectivityAnswer{AttemptId: "live", RequestId: 2, ResponderDeviceId: "forged"})
	routed := readV2ControlFrameFromPeer(t, initiator).GetConnectivityAnswer()
	if routed == nil || routed.RequestId != 2 || routed.ResponderDeviceId != target.deviceID {
		t.Fatalf("routed answer did not bind responder identity: %+v", routed)
	}
	if _, ok := h.v2Attempts["live"]; ok {
		t.Fatal("answer did not consume one-shot attempt")
	}

	h.v2Attempts["expired"] = v2Attempt{expiresAt: time.Now().Add(-time.Second)}
	h.handleConnectivityAnswerV2(target, &v2.ConnectivityAnswer{AttemptId: "expired", RequestId: 3})
	if _, ok := h.v2Attempts["expired"]; ok {
		t.Fatal("expired answer attempt was not pruned")
	}

	h.v2Attempts["reconnected"] = v2Attempt{
		initiator:             initiator.deviceID,
		initiatorConnectionID: "old-connection",
		target:                target.deviceID,
		targetConnectionID:    target.connectionID,
		expiresAt:             time.Now().Add(time.Minute),
	}
	h.handleConnectivityAnswerV2(target, &v2.ConnectivityAnswer{AttemptId: "reconnected", RequestId: 4})
	select {
	case frame := <-initiator.outbound:
		t.Fatalf("answer routed to a reconnected initiator: %+v", frame)
	default:
	}
}

type boundaryReservationFailure struct {
	Cache
}

func (boundaryReservationFailure) CreateReservation(context.Context, Reservation) error {
	return errors.New("reservation backend unavailable")
}

func TestRelayReserveFailureBoundaries(t *testing.T) {
	store := newMemoryStore(Config{})
	sender := boundaryHeartbeatPeer("reserve-sender")
	target := boundaryHeartbeatPeer("reserve-target")
	h := &hub{
		config:      withConfigDefaults(Config{Address: ":8080"}),
		peers:       map[string]*peer{sender.deviceID: sender, target.deviceID: target},
		presence:    store,
		presenceTTL: time.Minute,
	}
	readyTarget := func() {
		if _, _, err := store.TakePresence(context.Background(), target.deviceID, target.connectionID, Presence{}, time.Minute); err != nil {
			t.Fatal(err)
		}
		if err := store.TakeDiscovery(context.Background(), target.deviceID, target.connectionID, Discovery{DeviceID: target.deviceID, Revision: 1, RuntimeEpochLow: 1}, time.Minute); err != nil {
			t.Fatal(err)
		}
	}
	readError := func(t *testing.T) *v2.ProtocolError {
		t.Helper()
		return boundaryReadProtocolError(t, sender)
	}

	for _, test := range []struct {
		name, targetID string
		want           v2.ErrorCode
	}{
		{name: "missing target", targetID: "", want: v2.ErrorCode_ERROR_CODE_PROTOCOL},
		{name: "self target", targetID: sender.deviceID, want: v2.ErrorCode_ERROR_CODE_PROTOCOL},
		{name: "offline target", targetID: target.deviceID, want: v2.ErrorCode_ERROR_CODE_PEER_OFFLINE},
	} {
		t.Run(test.name, func(t *testing.T) {
			h.handleRelayReserveRequestV2(sender, &v2.RelayReserveRequest{RequestId: 1, AttemptId: test.name, TargetDeviceId: test.targetID})
			if got := readError(t); got.Code != test.want || got.AttemptId != test.name {
				t.Fatalf("reservation error=%+v, want code=%v", got, test.want)
			}
		})
	}

	if _, _, err := store.TakePresence(context.Background(), target.deviceID, target.connectionID, Presence{}, time.Minute); err != nil {
		t.Fatal(err)
	}
	h.handleRelayReserveRequestV2(sender, &v2.RelayReserveRequest{RequestId: 2, AttemptId: "not-ready", TargetDeviceId: target.deviceID})
	if got := readError(t); got.Code != v2.ErrorCode_ERROR_CODE_PEER_NOT_READY {
		t.Fatalf("not-ready reservation error=%+v", got)
	}
	readyTarget()
	h.presence = boundaryReservationFailure{Cache: store}
	h.handleRelayReserveRequestV2(sender, &v2.RelayReserveRequest{RequestId: 3, AttemptId: "store-failure", TargetDeviceId: target.deviceID})
	if got := readError(t); got.Code != v2.ErrorCode_ERROR_CODE_RESERVATION_FAILED {
		t.Fatalf("reservation backend error=%+v", got)
	}
}

func TestPeerQueueAndRateLimitBoundaries(t *testing.T) {
	p := &peer{
		outbound:           make(chan outboundFrame, 1),
		done:               make(chan struct{}),
		maxPendingFrames:   1,
		maxPendingBytes:    4,
		maxFramesPerSecond: 1,
		maxBytesPerSecond:  4,
	}
	frame := outboundFrame{data: []byte("four")}
	if !p.enqueue(frame) {
		t.Fatal("first frame was not queued")
	}
	if p.enqueue(frame) {
		t.Fatal("frame limit did not reject a second queued frame")
	}
	p.dequeue(frame)
	if p.enqueue(outboundFrame{data: []byte("too-long")}) {
		t.Fatal("byte limit did not reject an oversized frame")
	}
	p.dequeue(frame)
	close(p.done)
	if p.enqueue(frame) {
		t.Fatal("closed peer accepted a frame")
	}

	if !p.allowFrame(4) {
		t.Fatal("first rate-limited frame was rejected")
	}
	if p.allowFrame(1) {
		t.Fatal("frame-per-second limit did not reject a second frame")
	}
	p.windowStartedAt = time.Now().Add(-2 * time.Second)
	p.framesInWindow = 0
	p.bytesInWindow = 0
	if !p.allowFrame(4) {
		t.Fatal("rate limiter did not reset its window")
	}
}

func TestCoordinationTargetTicketBoundaries(t *testing.T) {
	h := &hub{coordinationTargets: map[string]coordinationTarget{}}
	peer := boundaryHeartbeatPeer("coordination")
	if target, ok := h.consumeCoordinationTarget(nil); ok || target != "" {
		t.Fatalf("nil peer ticket=%q ok=%v", target, ok)
	}
	h.rememberCoordinationTarget(nil, "target")
	h.rememberCoordinationTarget(peer, "target")
	if target, ok := h.consumeCoordinationTarget(peer); !ok || target != "target" {
		t.Fatalf("valid coordination ticket=%q ok=%v", target, ok)
	}
	if target, ok := h.consumeCoordinationTarget(peer); ok || target != "" {
		t.Fatalf("coordination ticket was not one-shot: %q ok=%v", target, ok)
	}
	h.coordinationTargets[peer.connectionID] = coordinationTarget{deviceID: "expired", expiresAt: time.Now().Add(-time.Second)}
	if target, ok := h.consumeCoordinationTarget(peer); ok || target != "" {
		t.Fatalf("expired coordination ticket=%q ok=%v", target, ok)
	}
}

func TestResolvePeerHandlerBoundaries(t *testing.T) {
	store := newMemoryStore(Config{})
	sender := boundaryHeartbeatPeer("resolve-sender")
	target := boundaryHeartbeatPeer("resolve-target")
	h := &hub{
		peers:               map[string]*peer{sender.deviceID: sender, target.deviceID: target},
		presence:            store,
		presenceTTL:         time.Minute,
		coordinationTargets: map[string]coordinationTarget{},
	}
	h.handleResolvePeerRequestV2(sender, &v2.ResolvePeerRequest{RequestId: 1})
	if got := boundaryReadProtocolError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_PROTOCOL {
		t.Fatalf("empty resolve target error=%+v", got)
	}
	if _, _, err := store.TakePresence(context.Background(), target.deviceID, target.connectionID, Presence{}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := store.TakeDiscovery(context.Background(), target.deviceID, target.connectionID, Discovery{DeviceID: target.deviceID, Revision: 1, RuntimeEpochLow: 1}, time.Minute); err != nil {
		t.Fatal(err)
	}
	h.handleResolvePeerRequestV2(sender, &v2.ResolvePeerRequest{RequestId: 2, TargetDeviceId: target.deviceID})
	response := readV2ControlFrameFromPeer(t, sender).GetResolvePeerResponse()
	if response == nil || response.Status != v2.ResolveStatus_RESOLVE_STATUS_READY || response.Discovery == nil {
		t.Fatalf("ready resolve response=%+v", response)
	}
	if targetID, ok := h.consumeCoordinationTarget(sender); !ok || targetID != target.deviceID {
		t.Fatalf("resolve did not establish offer gate: target=%q ok=%v", targetID, ok)
	}
}

func TestAdmitAuthenticatedDeviceFailureBoundaries(t *testing.T) {
	server := NewServer(Config{CredentialKey: []byte(mysqlTestCredentialKey), EnrollmentToken: "test-token", CredentialTTL: time.Hour})
	defer server.Close()
	claims := credentialClaims{DeviceID: "admit-device", ExpiresAt: time.Now().Add(time.Hour).Unix()}
	key := []byte("admit-key")
	if result := server.replaceEnrollment(claims.DeviceID, base64.RawURLEncoding.EncodeToString(key), "test", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("enrollment failed: %v", result)
	}
	if unlock, code, ok := server.admitAuthenticatedDevice(context.Background(), claims, key); !ok || code != relayErrorUnspecified || unlock == nil {
		t.Fatalf("valid admission result: unlock=%v code=%d ok=%v", unlock != nil, code, ok)
	} else {
		unlock()
	}
	expired := claims
	expired.ExpiresAt = time.Now().Add(-time.Minute).Unix()
	if unlock, code, ok := server.admitAuthenticatedDevice(context.Background(), expired, key); ok || unlock != nil || code != relayErrorCredentialExpired {
		t.Fatalf("expired admission: unlock=%v code=%d ok=%v", unlock != nil, code, ok)
	}
	if unlock, code, ok := server.admitAuthenticatedDevice(context.Background(), claims, []byte("wrong-key")); ok || unlock != nil || code != relayErrorAuthenticationFailed {
		t.Fatalf("key mismatch admission: unlock=%v code=%d ok=%v", unlock != nil, code, ok)
	}
	if recorded, err := server.store.RecordRevocation(context.Background(), claims.DeviceID, time.Now().Add(time.Hour)); err != nil || !recorded {
		t.Fatalf("revocation failed: recorded=%v err=%v", recorded, err)
	}
	if unlock, code, ok := server.admitAuthenticatedDevice(context.Background(), claims, key); ok || unlock != nil || code != relayErrorAuthenticationFailed {
		t.Fatalf("revoked admission: unlock=%v code=%d ok=%v", unlock != nil, code, ok)
	}
}

func TestAdminRateLimitResponseBoundaries(t *testing.T) {
	for _, test := range []struct {
		name, wantRetry string
		delay           time.Duration
	}{
		{name: "minimum retry", wantRetry: "1", delay: 0},
		{name: "rounded retry", wantRetry: "2", delay: 1500 * time.Millisecond},
	} {
		t.Run(test.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			writeAdminRateLimit(rec, test.delay)
			if rec.Code != http.StatusTooManyRequests || rec.Header().Get("Retry-After") != test.wantRetry {
				t.Fatalf("rate limit response status=%d retry=%q", rec.Code, rec.Header().Get("Retry-After"))
			}
		})
	}
}

func TestBroadcastV2ExcludesSenderAndFansOut(t *testing.T) {
	skipped := boundaryHeartbeatPeer("skip")
	target := boundaryHeartbeatPeer("target")
	h := &hub{peers: map[string]*peer{skipped.deviceID: skipped, target.deviceID: target}}
	h.broadcastV2(skipped.deviceID, &v2.RelayFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind:    &v2.RelayFrame_HeartbeatAck{HeartbeatAck: &v2.HeartbeatAck{RequestId: 9}},
	})
	select {
	case frame := <-skipped.outbound:
		t.Fatalf("excluded peer received broadcast: %+v", frame)
	default:
	}
	routed := readV2ControlFrameFromPeer(t, target).GetHeartbeatAck()
	if routed == nil || routed.RequestId != 9 {
		t.Fatalf("broadcast frame=%+v", routed)
	}
}

func TestDiscoveryPublishErrorMappingBoundaries(t *testing.T) {
	store := newMemoryStore(Config{})
	sender := boundaryHeartbeatPeer("discovery-errors")
	h := &hub{peers: map[string]*peer{sender.deviceID: sender}, presence: store, presenceTTL: time.Minute}
	h.handleDiscoveryPublishV2(sender, &v2.DiscoveryPublish{
		RequestId: 1,
		Snapshot:  &v2.DiscoverySnapshot{Revision: 1},
	})
	if got := boundaryReadProtocolError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_PROTOCOL {
		t.Fatalf("invalid snapshot mapping=%+v", got)
	}
	h.handleDiscoveryPublishV2(sender, &v2.DiscoveryPublish{
		RequestId: 2,
		Snapshot:  &v2.DiscoverySnapshot{Revision: 1, RuntimeEpoch: &v2.RuntimeEpoch{Low: 1}},
	})
	if got := boundaryReadProtocolError(t, sender); got.Code != v2.ErrorCode_ERROR_CODE_EPOCH_CONFLICT {
		t.Fatalf("missing presence mapping=%+v", got)
	}
}
