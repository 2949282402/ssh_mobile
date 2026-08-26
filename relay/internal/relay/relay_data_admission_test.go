package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

type relayReservationLookupStub struct {
	reservation Reservation
	present     bool
	err         error
}

func (s relayReservationLookupStub) GetReservation(context.Context, string) (Reservation, bool, error) {
	return s.reservation, s.present, s.err
}

func TestRelayDataAdmissionBindsLookupDeviceRoleAndToken(t *testing.T) {
	res := Reservation{
		ReservationID:     "00112233445566778899aabbccddeeff",
		InitiatorDeviceID: "device-a",
		ResponderDeviceID: "device-b",
		InitiatorToken:    []byte{1, 2, 3},
		ResponderToken:    []byte{4, 5, 6},
	}
	request := httptest.NewRequest("GET", "/v2/relay/"+res.ReservationID, nil)
	request.Header.Set("X-Relay-Token", "010203")

	tests := []struct {
		name   string
		store  relayReservationLookupStub
		device string
		want   relayDataAdmissionStatus
	}{
		{name: "lookup unavailable", store: relayReservationLookupStub{err: errors.New("lookup failed")}, device: "device-a", want: relayDataAdmissionUnavailable},
		{name: "reservation missing", store: relayReservationLookupStub{}, device: "device-a", want: relayDataAdmissionMissing},
		{name: "device not a role", store: relayReservationLookupStub{reservation: res, present: true}, device: "device-c", want: relayDataAdmissionForbidden},
		{name: "accepted", store: relayReservationLookupStub{reservation: res, present: true}, device: "device-a", want: relayDataAdmissionAccepted},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			gotReservation, gotRole, gotStatus := (relayDataAdmission{reservations: test.store}).authorize(
				context.Background(),
				request,
				res.ReservationID,
				test.device,
			)
			if gotStatus != test.want {
				t.Fatalf("status=%v want=%v", gotStatus, test.want)
			}
			if test.want == relayDataAdmissionAccepted {
				if gotReservation.ReservationID != res.ReservationID || gotRole != relayDataRoleInitiator {
					t.Fatalf("accepted binding mismatch: reservation=%+v role=%v", gotReservation, gotRole)
				}
			}
		})
	}
}

func TestRelayDataAdmissionAllowsOnlyTrackedActivePairRetryAfterSharedTTLDeletion(t *testing.T) {
	res := Reservation{
		ReservationID:     "00112233445566778899aabbccddeeff",
		InitiatorDeviceID: "device-a",
		ResponderDeviceID: "device-b",
		InitiatorToken:    []byte{1, 2, 3},
		ResponderToken:    []byte{4, 5, 6},
	}
	request := httptest.NewRequest(http.MethodGet, "/v2/relay/"+res.ReservationID, nil)
	request.Header.Set("X-Relay-Token", "010203")
	registry := newRelayDataRegistry(1)
	initiator := testRelayDataConnForRegistry(res.ReservationID, "device-a", relayDataRoleInitiator)
	initiator.res = res
	responder := testRelayDataConnForRegistry(res.ReservationID, "device-b", relayDataRoleResponder)
	responder.res = res
	if _, ok := registry.admitEndpoint(initiator); !ok {
		t.Fatal("initiator admission failed")
	}
	if _, ok := registry.admitEndpoint(responder); !ok {
		t.Fatal("responder admission failed")
	}

	gotReservation, gotRole, gotStatus := (relayDataAdmission{
		reservations: relayReservationLookupStub{},
		retries:      registry,
	}).authorize(context.Background(), request, res.ReservationID, "device-a")
	if gotStatus != relayDataAdmissionAccepted || gotRole != relayDataRoleInitiator || gotReservation.ReservationID != res.ReservationID {
		t.Fatalf("active retry binding mismatch: reservation=%+v role=%v status=%v", gotReservation, gotRole, gotStatus)
	}

	pendingRegistry := newRelayDataRegistry(1)
	pending := testRelayDataConnForRegistry(res.ReservationID, "device-a", relayDataRoleInitiator)
	pending.res = res
	if _, ok := pendingRegistry.admitEndpoint(pending); !ok {
		t.Fatal("pending initiator admission failed")
	}
	_, _, gotStatus = (relayDataAdmission{
		reservations: relayReservationLookupStub{},
		retries:      pendingRegistry,
	}).authorize(context.Background(), request, res.ReservationID, "device-a")
	if gotStatus != relayDataAdmissionMissing {
		t.Fatalf("initial pending pair bypassed shared TTL: status=%v", gotStatus)
	}
}

func TestRelayDataPreUpgradeErrorsUseStableJSONContract(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	server := newEndpointBoundaryServer(Config{})
	defer server.Close()
	encodedKey := base64.RawURLEncoding.EncodeToString(publicKey)
	if result := server.replaceEnrollment("device-a", encodedKey, "linux", RelayBootstrapProtocolVersion, time.Now()); result != enrollmentOK {
		t.Fatalf("seed enrollment result = %v", result)
	}

	requestFor := func(reservationID string, nonceByte byte) *http.Request {
		path := "/v2/relay/" + reservationID
		nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{nonceByte}, 32))
		credential, issueErr := issueCredential(server.config.CredentialKey, "device-a", publicKey, mustEnrollmentGeneration(t, server, "device-a"), time.Hour)
		if issueErr != nil {
			t.Fatal(issueErr)
		}
		request := httptest.NewRequest(http.MethodGet, path, nil)
		request.SetPathValue("reservation_id", reservationID)
		request.Header.Set("Authorization", "Bearer "+credential)
		setCurrentSignedDeviceProof(request.Header, http.MethodGet, path, privateKey, nonce)
		return request
	}

	validID := hex.EncodeToString(bytes.Repeat([]byte{0x11}, 16))
	if err := server.cache.CreateReservation(context.Background(), Reservation{
		ReservationID:     validID,
		InitiatorDeviceID: "device-a",
		ResponderDeviceID: "device-b",
		InitiatorToken:    bytes.Repeat([]byte{0x22}, 32),
		ResponderToken:    bytes.Repeat([]byte{0x33}, 32),
		ExpiresAtMs:       time.Now().Add(time.Minute).UnixMilli(),
	}); err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name   string
		status int
		code   relayErrorCode
		make   func() *http.Request
	}{
		{
			name: "invalid reservation id", status: http.StatusNotFound, code: relayErrorInvalidArgument,
			make: func() *http.Request {
				request := httptest.NewRequest(http.MethodGet, "/v2/relay/not-an-id", nil)
				request.SetPathValue("reservation_id", "not-an-id")
				return request
			},
		},
		{
			name: "missing reservation", status: http.StatusNotFound, code: relayErrorInvalidArgument,
			make: func() *http.Request {
				return requestFor(hex.EncodeToString(bytes.Repeat([]byte{0x44}, 16)), 1)
			},
		},
		{
			name: "forbidden token", status: http.StatusUnauthorized, code: relayErrorAuthenticationFailed,
			make: func() *http.Request {
				request := requestFor(validID, 2)
				request.Header.Set("X-Relay-Token", hex.EncodeToString(bytes.Repeat([]byte{0x55}, 32)))
				return request
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response := httptest.NewRecorder()
			server.connectRelayData(response, test.make())
			if response.Code != test.status {
				t.Fatalf("status=%d want=%d body=%s", response.Code, test.status, response.Body.String())
			}
			if response.Header().Get("Content-Type") != "application/json" {
				t.Fatalf("content type=%q", response.Header().Get("Content-Type"))
			}
			var body networkErrorResponse
			if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
				t.Fatalf("decode stable error: %v", err)
			}
			if body.Code != test.code || body.Operation != "connect_relay_data" || body.RetryDisposition != retryNoRetry {
				t.Fatalf("stable error=%+v", body)
			}
		})
	}
}
