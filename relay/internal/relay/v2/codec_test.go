package v2

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"google.golang.org/protobuf/proto"
)

// manifest mirrors protocol/relay_v2_testdata/manifest.json. expect values are
// kept as json.RawMessage-free `any` so each fixture assertion can pull exactly
// the keys it needs with a shared helper set.
type manifest struct {
	SchemaVersion int                       `json:"schema_version"`
	Constants     map[string]any            `json:"constants"`
	Enums         map[string]map[string]any `json:"enums"`
	Fixtures      []fixture                 `json:"fixtures"`
}

type fixture struct {
	Name      string         `json:"name"`
	File      string         `json:"file"`
	Transport string         `json:"transport"`
	Direction string         `json:"direction"`
	Expects   map[string]any `json:"expects"`
}

// findRepoRoot walks up from the test's working directory (the package source
// dir) until it finds protocol/relay_v2_testdata/manifest.json.
func findRepoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "protocol", "relay_v2_testdata", "manifest.json")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("repo root (protocol/relay_v2_testdata/manifest.json) not found")
		}
		dir = parent
	}
}

func mustLoadManifest(t *testing.T) *manifest {
	t.Helper()
	path := filepath.Join(findRepoRoot(t), "protocol", "relay_v2_testdata", "manifest.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	var m manifest
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	return &m
}

// ---------------------------------------------------------------------------
// Shared assertion helpers (manifest expectations are `any` from JSON).
// ---------------------------------------------------------------------------

func numKey(t *testing.T, e map[string]any, key string) (float64, bool) {
	t.Helper()
	v, ok := e[key]
	if !ok {
		return 0, false
	}
	f, ok := v.(float64)
	if !ok {
		t.Fatalf("expected numeric manifest key %q, got %T", key, v)
	}
	return f, true
}

func assertUint64(t *testing.T, got uint64, e map[string]any, key string) {
	t.Helper()
	if want, ok := numKey(t, e, key); ok && uint64(want) != got {
		t.Fatalf("%s = %d, want %d", key, got, uint64(want))
	}
}

func assertUint32(t *testing.T, got uint32, e map[string]any, key string) {
	t.Helper()
	if want, ok := numKey(t, e, key); ok && uint32(want) != got {
		t.Fatalf("%s = %d, want %d", key, got, uint32(want))
	}
}

func assertInt64(t *testing.T, got int64, e map[string]any, key string) {
	t.Helper()
	if want, ok := numKey(t, e, key); ok && int64(want) != got {
		t.Fatalf("%s = %d, want %d", key, got, int64(want))
	}
}

func assertStr(t *testing.T, got string, e map[string]any, key string) {
	t.Helper()
	if want, ok := e[key].(string); ok && got != want {
		t.Fatalf("%s = %q, want %q", key, got, want)
	}
}

func assertBool(t *testing.T, got bool, e map[string]any, key string) {
	t.Helper()
	if want, ok := e[key].(bool); ok && got != want {
		t.Fatalf("%s = %v, want %v", key, got, want)
	}
}

func assertHex(t *testing.T, got []byte, e map[string]any, key string) {
	t.Helper()
	if want, ok := e[key].(string); ok {
		gotHex := hex.EncodeToString(got)
		if gotHex != want {
			t.Fatalf("%s = %s, want %s", key, gotHex, want)
		}
	}
}

// assertEpoch compares a fixed64 runtime-epoch half against a manifest hex
// string like "0x6a09e667".
func assertEpoch(t *testing.T, got uint64, e map[string]any, key string) {
	t.Helper()
	want, ok := e[key].(string)
	if !ok {
		return
	}
	if !strings.HasPrefix(want, "0x") {
		t.Fatalf("expected 0x-prefixed hex for %s, got %q", key, want)
	}
	wantV, err := strconv.ParseUint(want[2:], 16, 64)
	if err != nil {
		t.Fatalf("bad hex %q: %v", want, err)
	}
	if got != wantV {
		t.Fatalf("%s = 0x%x, want %s", key, got, want)
	}
}

func assertEnumNumber[T ~int32](t *testing.T, got T, e map[string]any, key string) {
	t.Helper()
	if want, ok := numKey(t, e, key); ok && int32(got) != int32(want) {
		t.Fatalf("%s = %d, want %d", key, int32(got), int32(want))
	}
}

func assertEnumName[T interface{ String() string }](t *testing.T, got T, e map[string]any, key string) {
	t.Helper()
	if want, ok := e[key].(string); ok && got.String() != want {
		t.Fatalf("%s = %s, want %s", key, got.String(), want)
	}
}

func assertCapabilities(t *testing.T, caps []TransportCapability, e map[string]any) {
	t.Helper()
	if want, ok := e["transport_capabilities"].([]any); ok {
		if len(want) != len(caps) {
			t.Fatalf("transport_capabilities length = %d, want %d", len(caps), len(want))
		}
		for i, w := range want {
			if int(caps[i]) != int(w.(float64)) {
				t.Fatalf("transport_capabilities[%d] = %d, want %d", i, int(caps[i]), int(w.(float64)))
			}
		}
	}
	if want, ok := e["transport_capability_names"].([]any); ok {
		if len(want) != len(caps) {
			t.Fatalf("transport_capability_names length = %d, want %d", len(caps), len(want))
		}
		for i, w := range want {
			name := strings.TrimPrefix(caps[i].String(), "TRANSPORT_CAPABILITY_")
			if name != w.(string) {
				t.Fatalf("transport_capability_names[%d] = %s, want %s", i, name, w.(string))
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Golden fixture round-trip
// ---------------------------------------------------------------------------

func TestGoldenFixtures(t *testing.T) {
	m := mustLoadManifest(t)
	if len(m.Fixtures) != 22 {
		t.Fatalf("expected 22 fixtures, got %d", len(m.Fixtures))
	}
	root := findRepoRoot(t)
	for _, fx := range m.Fixtures {
		fx := fx
		t.Run(fx.Name, func(t *testing.T) {
			data, err := os.ReadFile(filepath.Join(root, "protocol", "relay_v2_testdata", fx.File))
			if err != nil {
				t.Fatalf("read fixture: %v", err)
			}
			switch fx.Transport {
			case "control":
				frame, err := DecodeControl(data)
				if err != nil {
					t.Fatalf("decode control frame: %v", err)
				}
				assertControlExpects(t, frame, fx.Expects)
				re, err := EncodeFrame(frame)
				if err != nil {
					t.Fatalf("re-encode control frame: %v", err)
				}
				if !bytes.Equal(re, data) {
					t.Fatalf("re-encode mismatch:\n got %x\nwant %x", re, data)
				}
			case "data":
				frame, err := DecodeData(data)
				if err != nil {
					t.Fatalf("decode data frame: %v", err)
				}
				assertDataExpects(t, frame, fx.Expects)
				re, err := EncodeDataFrame(frame)
				if err != nil {
					t.Fatalf("re-encode data frame: %v", err)
				}
				if !bytes.Equal(re, data) {
					t.Fatalf("re-encode mismatch:\n got %x\nwant %x", re, data)
				}
			default:
				t.Fatalf("unknown transport %q", fx.Transport)
			}
		})
	}
}

func assertControlExpects(t *testing.T, frame *RelayFrame, e map[string]any) {
	t.Helper()
	assertUint32(t, frame.Version, e, "version")
	name := KindName(frame)
	if want, ok := e["message"].(string); ok && name != want {
		t.Fatalf("message = %q, want %q", name, want)
	}
	switch name {
	case "ready":
		m := frame.GetReady()
		if m == nil {
			t.Fatal("expected ready message")
		}
		assertUint32(t, m.ProtocolVersion, e, "protocol_version")
		assertStr(t, m.DeviceId, e, "device_id")
		assertInt64(t, m.ServerTimeMs, e, "server_time_ms")
		assertUint32(t, m.HeartbeatIntervalS, e, "heartbeat_interval_s")
		assertUint32(t, m.PresenceTtlS, e, "presence_ttl_s")
	case "heartbeat":
		m := frame.GetHeartbeat()
		assertUint64(t, m.RequestId, e, "request_id")
		assertInt64(t, m.SentAtMs, e, "sent_at_ms")
	case "heartbeat_ack":
		m := frame.GetHeartbeatAck()
		assertUint64(t, m.RequestId, e, "request_id")
		assertInt64(t, m.ServerTimeMs, e, "server_time_ms")
	case "discovery_publish":
		m := frame.GetDiscoveryPublish()
		assertUint64(t, m.RequestId, e, "request_id")
		s := m.Snapshot
		if s == nil {
			t.Fatal("expected discovery snapshot")
		}
		assertSnapshotEpochRevision(t, s, e)
		assertCapabilities(t, s.TransportCapabilities, e)
		if want, ok := numKey(t, e, "candidate_count"); ok {
			got := 0
			if s.CandidateBundle != nil {
				got = len(s.CandidateBundle.Candidates)
			}
			if int(want) != got {
				t.Fatalf("candidate_count = %d, want %d", got, int(want))
			}
		}
		assertInt64(t, s.PublishedAtMs, e, "published_at_ms")
	case "discovery_ack":
		m := frame.GetDiscoveryAck()
		assertUint64(t, m.RequestId, e, "request_id")
		if m.RuntimeEpoch == nil {
			t.Fatal("expected runtime_epoch")
		}
		assertEpoch(t, m.RuntimeEpoch.High, e, "epoch_high")
		assertEpoch(t, m.RuntimeEpoch.Low, e, "epoch_low")
		assertUint32(t, m.Revision, e, "revision")
	case "resolve_peer_response":
		m := frame.GetResolvePeerResponse()
		assertUint64(t, m.RequestId, e, "request_id")
		assertEnumNumber(t, m.Status, e, "status")
		assertEnumName(t, m.Status, e, "status_name")
		if s := m.Discovery; s != nil {
			assertSnapshotEpochRevision(t, s, e)
		}
		assertUint32(t, m.RetryAfterMs, e, "retry_after_ms")
	case "connectivity_offer":
		m := frame.GetConnectivityOffer()
		assertUint64(t, m.RequestId, e, "request_id")
		assertStr(t, m.AttemptId, e, "attempt_id")
		assertStr(t, m.InitiatorDeviceId, e, "initiator_device_id")
		if m.InitiatorRuntimeEpoch == nil {
			t.Fatal("expected initiator_runtime_epoch")
		}
		assertEpoch(t, m.InitiatorRuntimeEpoch.High, e, "epoch_high")
		assertEpoch(t, m.InitiatorRuntimeEpoch.Low, e, "epoch_low")
		assertUint32(t, m.InitiatorRevision, e, "initiator_revision")
	case "connectivity_answer":
		m := frame.GetConnectivityAnswer()
		assertUint64(t, m.RequestId, e, "request_id")
		assertStr(t, m.AttemptId, e, "attempt_id")
		assertBool(t, m.Accepted, e, "accepted")
		assertStr(t, m.ResponderDeviceId, e, "responder_device_id")
		if m.ResponderRuntimeEpoch == nil {
			t.Fatal("expected responder_runtime_epoch")
		}
		assertEpoch(t, m.ResponderRuntimeEpoch.High, e, "epoch_high")
		assertEpoch(t, m.ResponderRuntimeEpoch.Low, e, "epoch_low")
		assertUint32(t, m.ResponderRevision, e, "responder_revision")
	case "presence_hint_snapshot":
		m := frame.GetPresenceHintSnapshot()
		if want, ok := numKey(t, e, "peer_count"); ok && int(want) != len(m.Peers) {
			t.Fatalf("peer_count = %d, want %d", len(m.Peers), int(want))
		}
		assertInt64(t, m.PublishedAtMs, e, "published_at_ms")
		if wantPeers, ok := e["peers"].([]any); ok {
			if len(wantPeers) != len(m.Peers) {
				t.Fatalf("peers length = %d, want %d", len(m.Peers), len(wantPeers))
			}
			for i, wp := range wantPeers {
				we, ok := wp.(map[string]any)
				if !ok {
					t.Fatalf("peers[%d] is not an object", i)
				}
				p := m.Peers[i]
				assertStr(t, p.DeviceId, we, "device_id")
				assertBool(t, p.Online, we, "online")
				if p.RuntimeEpoch != nil {
					assertEpoch(t, p.RuntimeEpoch.High, we, "epoch_high")
					assertEpoch(t, p.RuntimeEpoch.Low, we, "epoch_low")
				}
				assertUint32(t, p.Revision, we, "revision")
			}
		}
	case "peer_available_hint":
		m := frame.GetPeerAvailableHint()
		assertStr(t, m.DeviceId, e, "device_id")
		if m.RuntimeEpoch == nil {
			t.Fatal("expected runtime_epoch")
		}
		assertEpoch(t, m.RuntimeEpoch.High, e, "epoch_high")
		assertEpoch(t, m.RuntimeEpoch.Low, e, "epoch_low")
		assertUint32(t, m.Revision, e, "revision")
	case "peer_unavailable_hint":
		m := frame.GetPeerUnavailableHint()
		assertStr(t, m.DeviceId, e, "device_id")
		assertStr(t, m.Reason, e, "reason")
	case "relay_reserve_request":
		m := frame.GetRelayReserveRequest()
		assertUint64(t, m.RequestId, e, "request_id")
		assertStr(t, m.AttemptId, e, "attempt_id")
		assertStr(t, m.TargetDeviceId, e, "target_device_id")
		assertUint32(t, m.DesiredLifetimeS, e, "desired_lifetime_s")
	case "relay_reserve_response":
		m := frame.GetRelayReserveResponse()
		assertUint64(t, m.RequestId, e, "request_id")
		assertStr(t, m.AttemptId, e, "attempt_id")
		assertStr(t, m.ReservationId, e, "reservation_id")
		assertStr(t, m.RelayDataEndpoint, e, "relay_data_endpoint")
		assertInt64(t, m.ExpiresAtMs, e, "expires_at_ms")
		assertHex(t, m.LocalToken, e, "local_token_hex")
	case "incoming_relay_reservation":
		m := frame.GetIncomingRelayReservation()
		assertStr(t, m.AttemptId, e, "attempt_id")
		assertStr(t, m.ReservationId, e, "reservation_id")
		assertStr(t, m.InitiatorDeviceId, e, "initiator_device_id")
		assertStr(t, m.RelayDataEndpoint, e, "relay_data_endpoint")
		assertInt64(t, m.ExpiresAtMs, e, "expires_at_ms")
		assertHex(t, m.LocalToken, e, "local_token_hex")
	case "realtime_signal":
		m := frame.GetRealtimeSignal()
		assertUint64(t, m.RequestId, e, "request_id")
		assertStr(t, m.RealtimeId, e, "realtime_id")
		assertStr(t, m.TargetDeviceId, e, "target_device_id")
		assertEnumNumber(t, m.Kind, e, "kind")
		assertEnumName(t, m.Kind, e, "kind_name")
		assertUint64(t, m.Revision, e, "revision")
		assertHex(t, m.Payload, e, "payload_hex")
	case "protocol_error":
		m := frame.GetProtocolError()
		assertUint64(t, m.RequestId, e, "request_id")
		assertStr(t, m.AttemptId, e, "attempt_id")
		assertEnumNumber(t, m.Code, e, "code")
		assertEnumName(t, m.Code, e, "code_name")
		assertStr(t, m.Message, e, "error_message")
	default:
		t.Fatalf("unhandled control message %q", name)
	}
}

func assertSnapshotEpochRevision(t *testing.T, s *DiscoverySnapshot, e map[string]any) {
	t.Helper()
	if s.RuntimeEpoch == nil {
		t.Fatal("expected runtime_epoch")
	}
	assertEpoch(t, s.RuntimeEpoch.High, e, "epoch_high")
	assertEpoch(t, s.RuntimeEpoch.Low, e, "epoch_low")
	assertUint32(t, s.Revision, e, "revision")
}

func assertDataExpects(t *testing.T, frame *RelayDataFrame, e map[string]any) {
	t.Helper()
	assertUint32(t, frame.Version, e, "version")
	name := DataKindName(frame)
	if want, ok := e["message"].(string); ok && name != want {
		t.Fatalf("message = %q, want %q", name, want)
	}
	switch name {
	case "relay_data_connect":
		m := frame.GetConnect()
		assertStr(t, m.ReservationId, e, "reservation_id")
		assertHex(t, m.LocalToken, e, "local_token_hex")
	case "relay_data_payload":
		m := frame.GetPayload()
		assertUint64(t, m.Sequence, e, "sequence")
		assertHex(t, m.EncryptedPayload, e, "encrypted_payload_hex")
	case "relay_data_ack":
		m := frame.GetAck()
		assertUint64(t, m.Sequence, e, "sequence")
	case "relay_data_close":
		m := frame.GetClose()
		assertUint32(t, m.Reason, e, "reason")
	default:
		t.Fatalf("unhandled data message %q", name)
	}
}

// ---------------------------------------------------------------------------
// Constants and enums vs manifest
// ---------------------------------------------------------------------------

func TestConstantsMatchManifest(t *testing.T) {
	m := mustLoadManifest(t)
	checks := []struct {
		name string
		got  int
	}{
		{"RELAY_V2_VERSION", RELAY_V2_VERSION},
		{"FRAME_LENGTH_PREFIX_BYTES", FRAME_LENGTH_PREFIX_BYTES},
		{"MAX_RELAY_FRAME_BYTES", MAX_RELAY_FRAME_BYTES},
		{"MAX_RELAY_DATA_FRAME_BYTES", MAX_RELAY_DATA_FRAME_BYTES},
		{"MAX_DEVICE_ID_BYTES", MAX_DEVICE_ID_BYTES},
		{"MAX_ATTEMPT_ID_BYTES", MAX_ATTEMPT_ID_BYTES},
		{"MAX_REALTIME_ID_BYTES", MAX_REALTIME_ID_BYTES},
		{"MAX_REALTIME_SIGNAL_PAYLOAD_BYTES", MAX_REALTIME_SIGNAL_PAYLOAD_BYTES},
		{"MAX_DISCOVERY_CANDIDATES", MAX_DISCOVERY_CANDIDATES},
		{"MAX_DISCOVERY_CANDIDATE_BYTES", MAX_DISCOVERY_CANDIDATE_BYTES},
		{"MAX_DISCOVERY_CAPABILITIES", MAX_DISCOVERY_CAPABILITIES},
		{"RESERVATION_ID_BYTES", RESERVATION_ID_BYTES},
		{"RESERVATION_ID_HEX_CHARS", RESERVATION_ID_HEX_CHARS},
		{"RESERVATION_TOKEN_BYTES", RESERVATION_TOKEN_BYTES},
		{"HEARTBEAT_INTERVAL_S", HEARTBEAT_INTERVAL_S},
		{"PRESENCE_TTL_S", PRESENCE_TTL_S},
		{"SERVER_HEARTBEAT_MISSES_BEFORE_CLOSE", SERVER_HEARTBEAT_MISSES_BEFORE_CLOSE},
		{"RESERVATION_LIFETIME_S_DEFAULT", RESERVATION_LIFETIME_S_DEFAULT},
		{"RESERVATION_EXPIRY_GRACE_S", RESERVATION_EXPIRY_GRACE_S},
		{"RESOLVE_RETRY_HINT_NOT_READY_MS", RESOLVE_RETRY_HINT_NOT_READY_MS},
		{"RESOLVE_RETRY_HINT_UNKNOWN_MS", RESOLVE_RETRY_HINT_UNKNOWN_MS},
		{"DIRECT_CONNECT_WINDOW_MS", DIRECT_CONNECT_WINDOW_MS},
	}
	for _, c := range checks {
		want, ok := m.Constants[c.name]
		if !ok {
			t.Errorf("manifest missing constant %q", c.name)
			continue
		}
		wantN, ok := want.(float64)
		if !ok {
			t.Errorf("manifest constant %q is not numeric (%T)", c.name, want)
			continue
		}
		if int(wantN) != c.got {
			t.Errorf("%s = %d, manifest wants %d", c.name, c.got, int(wantN))
		}
	}
}

func TestEnumsMatchManifest(t *testing.T) {
	m := mustLoadManifest(t)
	enums := []struct {
		manifestName string
		value        map[string]int32
	}{
		{"TransportCapability", TransportCapability_value},
		{"ResolveStatus", ResolveStatus_value},
		{"RealtimeSignalKind", RealtimeSignalKind_value},
		{"ErrorCode", ErrorCode_value},
	}
	for _, en := range enums {
		want, ok := m.Enums[en.manifestName]
		if !ok {
			t.Errorf("manifest missing enum %q", en.manifestName)
			continue
		}
		for valueName, wantNum := range want {
			gotNum, ok := en.value[valueName]
			if !ok {
				t.Errorf("%s: Go enum missing value %q", en.manifestName, valueName)
				continue
			}
			if gotNum != int32(wantNum.(float64)) {
				t.Errorf("%s.%s = %d, manifest wants %d", en.manifestName, valueName, gotNum, int32(wantNum.(float64)))
			}
		}
		for valueName := range en.value {
			if _, ok := want[valueName]; !ok {
				t.Errorf("%s: Go enum has extra value %q not in manifest", en.manifestName, valueName)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Framing negatives (not golden fixtures)
// ---------------------------------------------------------------------------

// buildFrame constructs a valid wire frame around pb (used to build then corrupt
// negatives).
func buildFrame(pb []byte) []byte {
	frame := make([]byte, FRAME_LENGTH_PREFIX_BYTES+len(pb))
	// big-endian length
	frame[0] = byte(len(pb) >> 24)
	frame[1] = byte(len(pb) >> 16)
	frame[2] = byte(len(pb) >> 8)
	frame[3] = byte(len(pb))
	copy(frame[FRAME_LENGTH_PREFIX_BYTES:], pb)
	return frame
}

func TestDecodeControlFramingNegatives(t *testing.T) {
	valid := &RelayFrame{
		Version: RELAY_V2_VERSION,
		Kind:    &RelayFrame_Heartbeat{Heartbeat: &Heartbeat{RequestId: 1}},
	}
	wire, err := EncodeFrame(valid)
	if err != nil {
		t.Fatalf("encode valid frame: %v", err)
	}

	// Frame shorter than the length prefix.
	if _, err := DecodeControl(nil); ErrorCodeOf(err) != ErrorCode_ERROR_CODE_MALFORMED_FRAME {
		t.Errorf("nil frame: got error %v, want MALFORMED_FRAME", err)
	}
	if _, err := DecodeControl(wire[:2]); ErrorCodeOf(err) != ErrorCode_ERROR_CODE_MALFORMED_FRAME {
		t.Errorf("short frame: got error %v, want MALFORMED_FRAME", err)
	}

	// Length prefix != len(frame)-4.
	badLen := append([]byte(nil), wire...)
	badLen[3]++ // claim one extra payload byte
	if _, err := DecodeControl(badLen); ErrorCodeOf(err) != ErrorCode_ERROR_CODE_MALFORMED_FRAME {
		t.Errorf("length mismatch: got error %v, want MALFORMED_FRAME", err)
	}

	// Frame exceeds the route maximum.
	oversized := make([]byte, MAX_RELAY_FRAME_BYTES+1)
	if _, err := DecodeControl(oversized); ErrorCodeOf(err) != ErrorCode_ERROR_CODE_FRAME_TOO_LARGE {
		t.Errorf("oversized: got error %v, want FRAME_TOO_LARGE", err)
	}

	// Frame body too large for the route (prefix says so, total within frame max).
	bigBody := make([]byte, MAX_RELAY_FRAME_BYTES-FRAME_LENGTH_PREFIX_BYTES+1)
	if _, err := DecodeControl(buildFrame(bigBody)); ErrorCodeOf(err) != ErrorCode_ERROR_CODE_FRAME_TOO_LARGE {
		t.Errorf("oversized body: got error %v, want FRAME_TOO_LARGE", err)
	}

	// version != 2 (hand-built frame because EncodeFrame rejects it first).
	badVersion := &RelayFrame{Version: 3, Kind: &RelayFrame_Heartbeat{Heartbeat: &Heartbeat{RequestId: 1}}}
	pb, err := proto.Marshal(badVersion)
	if err != nil {
		t.Fatalf("marshal bad version: %v", err)
	}
	if _, err := DecodeControl(buildFrame(pb)); ErrorCodeOf(err) != ErrorCode_ERROR_CODE_PROTOCOL {
		t.Errorf("bad version: got error %v, want PROTOCOL", err)
	}

	// Truncated protobuf payload (valid prefix, garbage body).
	truncated := buildFrame([]byte{0x0a}) // tag for field 1 varint, missing value
	if _, err := DecodeControl(truncated); ErrorCodeOf(err) != ErrorCode_ERROR_CODE_MALFORMED_FRAME {
		t.Errorf("truncated proto: got error %v, want MALFORMED_FRAME", err)
	}
}

func TestDecodeDataFramingNegatives(t *testing.T) {
	valid := &RelayDataFrame{
		Version: RELAY_V2_VERSION,
		Kind:    &RelayDataFrame_Close{Close: &RelayDataClose{Reason: 0}},
	}
	wire, err := EncodeDataFrame(valid)
	if err != nil {
		t.Fatalf("encode valid data frame: %v", err)
	}

	if _, err := DecodeData(nil); ErrorCodeOf(err) != ErrorCode_ERROR_CODE_MALFORMED_FRAME {
		t.Errorf("nil frame: got error %v, want MALFORMED_FRAME", err)
	}
	badLen := append([]byte(nil), wire...)
	badLen[0]++
	if _, err := DecodeData(badLen); ErrorCodeOf(err) != ErrorCode_ERROR_CODE_MALFORMED_FRAME {
		t.Errorf("length mismatch: got error %v, want MALFORMED_FRAME", err)
	}
	oversized := make([]byte, MAX_RELAY_DATA_FRAME_BYTES+1)
	if _, err := DecodeData(oversized); ErrorCodeOf(err) != ErrorCode_ERROR_CODE_FRAME_TOO_LARGE {
		t.Errorf("oversized: got error %v, want FRAME_TOO_LARGE", err)
	}
	badVersion := &RelayDataFrame{Version: 1, Kind: &RelayDataFrame_Close{Close: &RelayDataClose{Reason: 0}}}
	pb, err := proto.Marshal(badVersion)
	if err != nil {
		t.Fatalf("marshal bad version: %v", err)
	}
	if _, err := DecodeData(buildFrame(pb)); ErrorCodeOf(err) != ErrorCode_ERROR_CODE_PROTOCOL {
		t.Errorf("bad version: got error %v, want PROTOCOL", err)
	}
}

func TestUnknownOneofTagIsTolerated(t *testing.T) {
	// A RelayFrame with version=2 and an unknown oneof tag (30, reserved) plus a
	// known field must decode without error; the unknown tag is preserved as
	// unknown fields and the known one still surfaces.
	unknownTag := encodeFieldVarint(30, 1) // field 30, varint value 1 — reserved, unknown
	versionField := encodeFieldVarint(1, RELAY_V2_VERSION)
	heartbeatField := encodeFieldMessage(11, mustMarshal(t, &Heartbeat{RequestId: 7}))
	frame, err := DecodeControl(buildFrame(append(append(versionField, heartbeatField...), unknownTag...)))
	if err != nil {
		t.Fatalf("decode with unknown oneof tag: %v", err)
	}
	if frame.Version != RELAY_V2_VERSION {
		t.Errorf("version = %d, want %d", frame.Version, RELAY_V2_VERSION)
	}
	if got := frame.GetHeartbeat(); got == nil || got.RequestId != 7 {
		t.Errorf("heartbeat = %+v, want request_id=7", got)
	}
}

func TestEncodeFrameRejectsOversizedAndBadVersion(t *testing.T) {
	// EncodeFrame rejects oversized control frames.
	big := &RelayFrame{
		Version: RELAY_V2_VERSION,
		Kind:    &RelayFrame_RealtimeSignal{RealtimeSignal: &RealtimeSignal{Payload: make([]byte, MAX_RELAY_FRAME_BYTES)}},
	}
	if _, err := EncodeFrame(big); ErrorCodeOf(err) != ErrorCode_ERROR_CODE_FRAME_TOO_LARGE {
		t.Errorf("oversized encode: got error %v, want FRAME_TOO_LARGE", err)
	}
	if _, err := EncodeFrame(&RelayFrame{Version: 3}); ErrorCodeOf(err) != ErrorCode_ERROR_CODE_PROTOCOL {
		t.Errorf("bad version encode: got error %v, want PROTOCOL", err)
	}
	if _, err := EncodeDataFrame(&RelayDataFrame{Version: 3}); ErrorCodeOf(err) != ErrorCode_ERROR_CODE_PROTOCOL {
		t.Errorf("bad version data encode: got error %v, want PROTOCOL", err)
	}
	if _, err := EncodeFrame(nil); err == nil {
		t.Error("EncodeFrame(nil) succeeded, want error")
	}
}

func TestErrorCodeOfNil(t *testing.T) {
	if got := ErrorCodeOf(nil); got != ErrorCode_ERROR_CODE_UNSPECIFIED {
		t.Errorf("ErrorCodeOf(nil) = %v, want UNSPECIFIED", got)
	}
	if got := ErrorCodeOf(fmt.Errorf("unrelated")); got != ErrorCode_ERROR_CODE_UNSPECIFIED {
		t.Errorf("ErrorCodeOf(unrelated) = %v, want UNSPECIFIED", got)
	}
}

// ---------------------------------------------------------------------------
// Minimal wire encoders for negative-test construction only (avoids pulling the
// full hand-written codec into the test path).
// ---------------------------------------------------------------------------

func mustMarshal(t *testing.T, m proto.Message) []byte {
	t.Helper()
	b, err := proto.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}

func encodeVarint(n uint64) []byte {
	var out []byte
	for {
		b := byte(n & 0x7f)
		n >>= 7
		if n != 0 {
			out = append(out, b|0x80)
		} else {
			out = append(out, b)
			return out
		}
	}
}

func encodeFieldVarint(field int, value uint64) []byte {
	return append(encodeVarint(uint64(field<<3|0)), encodeVarint(value)...)
}

func encodeFieldMessage(field int, payload []byte) []byte {
	out := encodeVarint(uint64(field<<3 | 2))
	out = append(out, encodeVarint(uint64(len(payload)))...)
	return append(out, payload...)
}
