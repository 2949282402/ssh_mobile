package relay

import (
	"crypto/ed25519"
	"encoding/hex"
	"net/http"
	"testing"
	"time"
)

// TestNetworkV2ExpiredCredentialCannotOpenDataSocket closes the data-plane
// side of the expired-credential admission matrix. Reservation role/token
// checks are separate from device credential verification; an expired device
// credential must fail at the WebSocket upgrade before it can claim either
// role or send a RelayDataConnect frame.
func TestNetworkV2ExpiredCredentialCannotOpenDataSocket(t *testing.T) {
	server, httpServer := newV2TestServer(t)
	_, privateKey := enrollV2(t, httpServer.URL, "device-a")
	res := createRelayDataTestReservation(t, server, httpServer, "device-a", "device-b")

	publicKey := privateKey.Public().(ed25519.PublicKey)
	expiredCredential, err := issueCredential(
		server.config.CredentialKey,
		"device-a",
		publicKey,
		-time.Second,
	)
	if err != nil {
		t.Fatalf("issue expired credential: %v", err)
	}

	identity := relayDataTestIdentity{
		credential: expiredCredential,
		privateKey: privateKey,
	}
	_, response, err := dialRelayDataWithIdentity(
		httpServer.URL,
		res.ReservationID,
		hex.EncodeToString(res.InitiatorToken),
		identity,
	)
	if err == nil || response == nil || response.StatusCode != http.StatusUnauthorized {
		t.Fatalf(
			"expired credential must not open v2 data socket: status=%v err=%v",
			statusOf(response),
			err,
		)
	}
}
