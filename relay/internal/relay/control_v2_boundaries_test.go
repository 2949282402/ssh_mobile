package relay

import (
	"encoding/base64"
	"testing"
	"time"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

func TestValidateV2ClientRequestBoundaries(t *testing.T) {
	tests := []struct {
		name      string
		frame     *v2.RelayFrame
		requestID uint64
		wantErr   bool
	}{
		{name: "nil frame", frame: nil},
		{name: "empty oneof", frame: &v2.RelayFrame{Version: v2.RELAY_V2_VERSION}},
		{
			name:    "heartbeat requires request id",
			frame:   &v2.RelayFrame{Kind: &v2.RelayFrame_Heartbeat{Heartbeat: &v2.Heartbeat{}}},
			wantErr: true,
		},
		{
			name: "heartbeat accepts request id",
			frame: &v2.RelayFrame{Kind: &v2.RelayFrame_Heartbeat{
				Heartbeat: &v2.Heartbeat{RequestId: 1},
			}},
			requestID: 1,
		},
		{
			name: "discovery publish requires request id",
			frame: &v2.RelayFrame{Kind: &v2.RelayFrame_DiscoveryPublish{
				DiscoveryPublish: &v2.DiscoveryPublish{},
			}},
			wantErr: true,
		},
		{
			name: "resolve requires request id",
			frame: &v2.RelayFrame{Kind: &v2.RelayFrame_ResolvePeerRequest{
				ResolvePeerRequest: &v2.ResolvePeerRequest{},
			}},
			wantErr: true,
		},
		{
			name: "offer requires attempt id",
			frame: &v2.RelayFrame{Kind: &v2.RelayFrame_ConnectivityOffer{
				ConnectivityOffer: &v2.ConnectivityOffer{RequestId: 2},
			}},
			requestID: 2,
			wantErr:   true,
		},
		{
			name: "answer accepts request and attempt",
			frame: &v2.RelayFrame{Kind: &v2.RelayFrame_ConnectivityAnswer{
				ConnectivityAnswer: &v2.ConnectivityAnswer{RequestId: 3, AttemptId: "attempt-3"},
			}},
			requestID: 3,
		},
		{
			name: "reserve requires attempt id",
			frame: &v2.RelayFrame{Kind: &v2.RelayFrame_RelayReserveRequest{
				RelayReserveRequest: &v2.RelayReserveRequest{RequestId: 4},
			}},
			requestID: 4,
			wantErr:   true,
		},
		{
			name: "realtime requires request id",
			frame: &v2.RelayFrame{Kind: &v2.RelayFrame_RealtimeSignal{
				RealtimeSignal: &v2.RealtimeSignal{},
			}},
			wantErr: true,
		},
		{
			name:  "server direction is not a client request",
			frame: &v2.RelayFrame{Kind: &v2.RelayFrame_Ready{Ready: &v2.Ready{}}},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			requestID, err := validateV2ClientRequest(test.frame)
			if requestID != test.requestID {
				t.Fatalf("request id = %d, want %d", requestID, test.requestID)
			}
			if (err != nil) != test.wantErr {
				t.Fatalf("error = %v, wantErr=%v", err, test.wantErr)
			}
		})
	}
}

func TestDiscoverySnapshotV2ValidationBoundaries(t *testing.T) {
	valid := &v2.DiscoverySnapshot{
		RuntimeEpoch: &v2.RuntimeEpoch{Low: 1},
		Revision:     1,
	}
	tests := []struct {
		name     string
		snapshot *v2.DiscoverySnapshot
		wantErr  bool
	}{
		{name: "valid", snapshot: valid},
		{name: "nil", snapshot: nil, wantErr: true},
		{name: "zero revision", snapshot: &v2.DiscoverySnapshot{RuntimeEpoch: &v2.RuntimeEpoch{Low: 1}}, wantErr: true},
		{name: "missing epoch", snapshot: &v2.DiscoverySnapshot{Revision: 1}, wantErr: true},
		{name: "zero epoch", snapshot: &v2.DiscoverySnapshot{RuntimeEpoch: &v2.RuntimeEpoch{}, Revision: 1}, wantErr: true},
		{
			name: "too many capabilities",
			snapshot: &v2.DiscoverySnapshot{
				RuntimeEpoch:          &v2.RuntimeEpoch{Low: 1},
				Revision:              1,
				TransportCapabilities: make([]v2.TransportCapability, maxDiscoveryCapabilities+1),
			},
			wantErr: true,
		},
		{
			name: "too many candidates",
			snapshot: &v2.DiscoverySnapshot{
				RuntimeEpoch: &v2.RuntimeEpoch{Low: 1},
				Revision:     1,
				CandidateBundle: &v2.CandidateBundle{
					Candidates: make([][]byte, maxDiscoveryCandidates+1),
				},
			},
			wantErr: true,
		},
		{
			name: "oversized candidate",
			snapshot: &v2.DiscoverySnapshot{
				RuntimeEpoch: &v2.RuntimeEpoch{Low: 1},
				Revision:     1,
				CandidateBundle: &v2.CandidateBundle{
					Candidates: [][]byte{make([]byte, maxDiscoveryCandidateBytes+1)},
				},
			},
			wantErr: true,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if (validateDiscoverySnapshotV2(test.snapshot) != nil) != test.wantErr {
				t.Fatalf("validation result mismatch for %s", test.name)
			}
		})
	}
}

func TestDiscoveryConversionsPreserveOpaqueAndNumericFields(t *testing.T) {
	updatedAt := time.UnixMilli(123456)
	snapshot := &v2.DiscoverySnapshot{
		RuntimeEpoch:          &v2.RuntimeEpoch{High: 7, Low: 8},
		Revision:              9,
		TransportCapabilities: []v2.TransportCapability{v2.TransportCapability_TRANSPORT_CAPABILITY_TCP},
		CandidateBundle:       &v2.CandidateBundle{Candidates: [][]byte{{0, 1, 2}}},
		PublishedAtMs:         updatedAt.UnixMilli(),
	}
	discovery := discoveryFromV2("device-a", snapshot)
	if discovery.DeviceID != "device-a" || discovery.RuntimeEpochHigh != 7 || discovery.RuntimeEpochLow != 8 || discovery.Revision != 9 {
		t.Fatalf("discovery identity fields not preserved: %+v", discovery)
	}
	if len(discovery.Capabilities) != 1 || discovery.Capabilities[0] != "2" {
		t.Fatalf("capability conversion mismatch: %+v", discovery.Capabilities)
	}
	if len(discovery.Candidates) != 1 || discovery.Candidates[0] != base64.StdEncoding.EncodeToString([]byte{0, 1, 2}) {
		t.Fatalf("candidate conversion mismatch: %+v", discovery.Candidates)
	}
	converted := discoveryToV2(Discovery{
		RuntimeEpochHigh: 7,
		RuntimeEpochLow:  8,
		Revision:         9,
		Capabilities:     []string{"2", "not-a-number", "4294967296"},
		Candidates:       []string{discovery.Candidates[0], "%%%"},
		UpdatedAt:        updatedAt,
	})
	if converted.RuntimeEpoch.High != 7 || converted.RuntimeEpoch.Low != 8 || converted.Revision != 9 || converted.PublishedAtMs != updatedAt.UnixMilli() {
		t.Fatalf("snapshot identity fields not preserved: %+v", converted)
	}
	if len(converted.TransportCapabilities) != 1 || converted.TransportCapabilities[0] != v2.TransportCapability_TRANSPORT_CAPABILITY_TCP {
		t.Fatalf("numeric capability filtering mismatch: %+v", converted.TransportCapabilities)
	}
	if len(converted.CandidateBundle.Candidates) != 1 {
		t.Fatalf("invalid candidate should be filtered: %+v", converted.CandidateBundle)
	}
}

func TestResolveStatusErrorBoundaries(t *testing.T) {
	tests := []struct {
		status  v2.ResolveStatus
		code    v2.ErrorCode
		message string
	}{
		{v2.ResolveStatus_RESOLVE_STATUS_OFFLINE, v2.ErrorCode_ERROR_CODE_PEER_OFFLINE, "target peer is offline"},
		{v2.ResolveStatus_RESOLVE_STATUS_NOT_READY, v2.ErrorCode_ERROR_CODE_PEER_NOT_READY, "target peer is not ready"},
		{v2.ResolveStatus_RESOLVE_STATUS_UNKNOWN, v2.ErrorCode_ERROR_CODE_CONTROL_UNAVAILABLE, "control backend unavailable"},
		{v2.ResolveStatus_RESOLVE_STATUS_READY, v2.ErrorCode_ERROR_CODE_UNSPECIFIED, ""},
		{v2.ResolveStatus(99), v2.ErrorCode_ERROR_CODE_CONTROL_UNAVAILABLE, "control backend returned an unknown resolve status"},
	}
	for _, test := range tests {
		code, message := resolveStatusError(test.status)
		if code != test.code || message != test.message {
			t.Errorf("status %v = (%v, %q), want (%v, %q)", test.status, code, message, test.code, test.message)
		}
	}
}
