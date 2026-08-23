package relay

import (
	"context"
	"errors"
	"net/http/httptest"
	"testing"
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
	request := httptest.NewRequest("GET", "/v2/relay/"+res.ReservationID+"?token=010203", nil)

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
