package relay

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestRelayDataValidationBoundaries(t *testing.T) {
	validID := "00112233445566778899aabbccddeeff"
	cases := []struct {
		name string
		id   string
		want bool
	}{
		{name: "valid lowercase hex", id: validID, want: true},
		{name: "uppercase rejected", id: "00112233445566778899AABBCCDDEEFF", want: false},
		{name: "wrong length rejected", id: validID[:31], want: false},
		{name: "non hex rejected", id: validID[:31] + "g", want: false},
	}
	for _, test := range cases {
		t.Run("reservation id/"+test.name, func(t *testing.T) {
			if got := validReservationID(test.id); got != test.want {
				t.Fatalf("validReservationID(%q) = %v, want %v", test.id, got, test.want)
			}
		})
	}

	reservation := Reservation{
		ReservationID:     validID,
		InitiatorDeviceID: "device-a",
		ResponderDeviceID: "device-b",
		InitiatorToken:    []byte{1, 2, 3},
		ResponderToken:    []byte{4, 5, 6},
	}
	tokenCases := []struct {
		name       string
		queryToken string
		header     string
		role       relayDataRole
		want       bool
	}{
		{name: "initiator token", header: "010203", role: relayDataRoleInitiator, want: true},
		{name: "responder token", header: "040506", role: relayDataRoleResponder, want: true},
		{name: "wrong token", header: "aabbcc", role: relayDataRoleInitiator, want: false},
		{name: "invalid encoding", header: "not-hex", role: relayDataRoleInitiator, want: false},
		{name: "missing header", role: relayDataRoleInitiator, want: false},
		{name: "unknown role", header: "010203", role: relayDataRole(99), want: false},
		{name: "query token rejected", queryToken: "010203", header: "010203", role: relayDataRoleInitiator, want: false},
	}
	for _, test := range tokenCases {
		t.Run("relay token/"+test.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, PathRelayDataV2+validID, nil)
			if test.queryToken != "" {
				request.URL.RawQuery = "token=" + test.queryToken
			}
			if test.header != "" {
				request.Header.Set("X-Relay-Token", test.header)
			}
			if got := validRelayTokenForRole(request, reservation, test.role); got != test.want {
				t.Fatalf("validRelayTokenForRole() = %v, want %v", got, test.want)
			}
		})
	}

	request := httptest.NewRequest(http.MethodGet, PathRelayDataV2+validID, nil)
	request.Header.Set("X-Relay-Token", "040506")
	if !validRelayToken(request, reservation) {
		t.Fatal("validRelayToken did not accept the responder token")
	}
	if role, ok := relayDataRoleForDevice(reservation, "device-a"); !ok || role != relayDataRoleInitiator {
		t.Fatalf("initiator role = %v/%v, want %v/true", role, ok, relayDataRoleInitiator)
	}
	if role, ok := relayDataRoleForDevice(reservation, "device-b"); !ok || role != relayDataRoleResponder {
		t.Fatalf("responder role = %v/%v, want %v/true", role, ok, relayDataRoleResponder)
	}
	for _, deviceID := range []string{"", "device-c"} {
		if _, ok := relayDataRoleForDevice(reservation, deviceID); ok {
			t.Fatalf("unexpected role for device %q", deviceID)
		}
	}
	if _, ok := relayDataRoleForDevice(Reservation{InitiatorDeviceID: "same", ResponderDeviceID: "same"}, "same"); ok {
		t.Fatal("reservation with identical device roles was accepted")
	}
}

func TestDiscoveryContentSetComparisonBoundaries(t *testing.T) {
	base := Discovery{Candidates: []string{"candidate-a", "candidate-b"}, Capabilities: []string{"tcp", "quic"}}
	cases := []struct {
		name  string
		other Discovery
		want  bool
	}{
		{name: "same sets in different order", other: Discovery{Candidates: []string{"candidate-b", "candidate-a"}, Capabilities: []string{"quic", "tcp"}}, want: true},
		{name: "different length", other: Discovery{Candidates: []string{"candidate-a"}, Capabilities: base.Capabilities}, want: false},
		{name: "different member", other: Discovery{Candidates: []string{"candidate-a", "candidate-c"}, Capabilities: base.Capabilities}, want: false},
		{name: "duplicate changes multiset", other: Discovery{Candidates: []string{"candidate-a", "candidate-a"}, Capabilities: base.Capabilities}, want: false},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			if got := sameDiscoveryContent(base, test.other); got != test.want {
				t.Fatalf("sameDiscoveryContent() = %v, want %v", got, test.want)
			}
		})
	}
	if !sameStringSet(nil, nil) || sameStringSet(nil, []string{"value"}) {
		t.Fatal("sameStringSet empty-set behavior is incorrect")
	}
}

func TestPendingAdmissionMapIsInitialized(t *testing.T) {
	admissions := newPendingAdmissionMap()
	if admissions == nil {
		t.Fatal("newPendingAdmissionMap returned nil")
	}
	admissions["device"] = &peer{}
	if len(admissions) != 1 || admissions["device"] == nil {
		t.Fatal("pending admission map is not writable")
	}
}

func TestRefreshV2DelegatesValidation(t *testing.T) {
	server := newEndpointBoundaryServer(Config{})
	defer server.Close()
	request := httptest.NewRequest(http.MethodPost, PathRefreshV2, strings.NewReader("{"))
	response := httptest.NewRecorder()

	server.refreshV2(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("refreshV2 status = %d, want %d", response.Code, http.StatusBadRequest)
	}
}

func TestRemoteIPNormalizesSocketAndBareAddresses(t *testing.T) {
	cases := []struct {
		name  string
		input string
		want  string
		valid bool
	}{
		{name: "ipv4 socket", input: " 192.0.2.10:22 ", want: "192.0.2.10", valid: true},
		{name: "ipv6 socket", input: "[2001:db8::10]:443", want: "2001:db8::10", valid: true},
		{name: "bare ipv4", input: "198.51.100.4", want: "198.51.100.4", valid: true},
		{name: "malformed", input: "not-an-address", valid: false},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			got, valid := remoteIP(test.input)
			if valid != test.valid {
				t.Fatalf("remoteIP(%q) valid = %v, want %v", test.input, valid, test.valid)
			}
			if valid && got.String() != test.want {
				t.Fatalf("remoteIP(%q) = %q, want %q", test.input, got, test.want)
			}
		})
	}
}

func TestParseClientSocketAddrRejectsZeroPort(t *testing.T) {
	if got, valid := parseClientSocketAddr("192.0.2.10:0"); valid || got != "" {
		t.Fatalf("parseClientSocketAddr zero port = %q/%v, want empty/false", got, valid)
	}
}

func TestIssueCredentialRejectsInvalidGeneration(t *testing.T) {
	if _, err := issueCredential(nil, "device", nil, 0, time.Minute); err == nil {
		t.Fatal("issueCredential accepted a non-positive enrollment generation")
	}
}

type coverageSeedStore struct {
	Storage
	putResult enrollmentResult
	putErr    error
}

func (s coverageSeedStore) PutEnrollment(context.Context, *EnrolledDevice) (enrollmentResult, error) {
	return s.putResult, s.putErr
}

func TestSeedEnrollmentsFailsClosedAtValidationAndStorageBoundaries(t *testing.T) {
	server := NewServer(Config{})
	defer server.Close()
	device := EnrolledDevice{DeviceID: "seed-device", ProtocolVersion: server.config.ProtocolVersion}

	if err := server.SeedEnrollments(context.Background(), []EnrolledDevice{{DeviceID: "legacy", ProtocolVersion: server.config.ProtocolVersion + 1}}); err == nil {
		t.Fatal("unsupported seed protocol was accepted")
	}

	heldUnlock, locked := server.lockDeviceContext(context.Background(), device.DeviceID)
	if !locked {
		t.Fatal("failed to hold seed device lock")
	}
	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	if err := server.SeedEnrollments(canceled, []EnrolledDevice{device}); !errors.Is(err, context.Canceled) {
		heldUnlock()
		t.Fatalf("canceled seed error = %v, want context.Canceled", err)
	}
	heldUnlock()

	storeErr := errors.New("seed store unavailable")
	server.store = coverageSeedStore{Storage: server.store, putResult: enrollmentOK, putErr: storeErr}
	if err := server.SeedEnrollments(context.Background(), []EnrolledDevice{device}); !errors.Is(err, storeErr) {
		t.Fatalf("seed store error = %v, want %v", err, storeErr)
	}

	server.store = coverageSeedStore{Storage: server.store, putResult: enrollmentResult(99)}
	if err := server.SeedEnrollments(context.Background(), []EnrolledDevice{device}); err == nil {
		t.Fatal("unexpected seed result was accepted")
	}
}

func TestLockDeviceAcquiresAndReleasesDeviceStripe(t *testing.T) {
	server := NewServer(Config{})
	defer server.Close()
	unlock := server.lockDevice("lock-device")
	unlock()
}
