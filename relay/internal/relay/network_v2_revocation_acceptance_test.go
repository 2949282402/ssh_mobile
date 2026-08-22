package relay

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/ssh-mobile/relay/internal/relay/v2"
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

func dialControlV2ForRevocation(baseURL, credential string, nonceByte byte, privateKey ed25519.PrivateKey) (*websocket.Conn, *http.Response, error) {
	relayURL, err := url.Parse(baseURL)
	if err != nil {
		return nil, nil, err
	}
	relayURL.Scheme = "ws"
	relayURL.Path = "/v2/control"
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{nonceByte}, 32))
	headers := http.Header{}
	headers.Set("Authorization", "Bearer "+credential)
	headers.Set("X-Relay-Nonce", nonce)
	headers.Set("X-Relay-Signature", base64.RawURLEncoding.EncodeToString(
		ed25519.Sign(privateKey, []byte("GET\n/v2/control\n"+nonce)),
	))
	return websocket.DefaultDialer.Dial(relayURL.String(), headers)
}

// TestNetworkV2RevokeAdmissionMatrix verifies the complete same-instance
// revocation boundary: active control, an upgraded-but-not-connected data
// socket, an active data pair and its counterpart are all closed, while every
// new control/data admission using the revoked credential fails before upgrade.
func TestNetworkV2RevokeAdmissionMatrix(t *testing.T) {
	server, httpServer := newV2TestServer(t)
	credentialA, privateKeyA := enrollV2(t, httpServer.URL, "device-a")
	credentialB, privateKeyB := enrollV2(t, httpServer.URL, "device-b")

	controlA := dialControlV2(t, httpServer.URL, credentialA, "device-a", 0xa1, privateKeyA)
	defer controlA.Close()
	controlB := dialControlV2(t, httpServer.URL, credentialB, "device-b", 0xb1, privateKeyB)
	defer controlB.Close()

	pending := createRelayDataTestReservation(t, server, httpServer, "device-a", "device-b")
	pendingA := dialRelayData(t, httpServer.URL, pending.ReservationID, hex.EncodeToString(pending.InitiatorToken))
	defer pendingA.Close()

	active := createRelayDataTestReservation(t, server, httpServer, "device-a", "device-b")
	activeA := dialRelayData(t, httpServer.URL, active.ReservationID, hex.EncodeToString(active.InitiatorToken))
	defer activeA.Close()
	activeB := dialRelayData(t, httpServer.URL, active.ReservationID, hex.EncodeToString(active.ResponderToken))
	defer activeB.Close()
	writeV2DataFrame(t, activeA, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{
			ReservationId: active.ReservationID,
			LocalToken:    active.InitiatorToken,
		}},
	})
	waitRelayPending(t, server, active.ReservationID, true)
	writeV2DataFrame(t, activeB, &v2.RelayDataFrame{
		Version: v2.RELAY_V2_VERSION,
		Kind: &v2.RelayDataFrame_Connect{Connect: &v2.RelayDataConnect{
			ReservationId: active.ReservationID,
			LocalToken:    active.ResponderToken,
		}},
	})
	waitRelayPending(t, server, active.ReservationID, false)
	readRelayDataPairReady(t, activeA, active.ReservationID)
	readRelayDataPairReady(t, activeB, active.ReservationID)

	revokeRequest := httptest.NewRequest(http.MethodPost, "/api/admin/v1/devices/device-a/revoke", nil)
	revokeRequest.SetPathValue("deviceId", "device-a")
	revokeResponse := httptest.NewRecorder()
	server.adminRevokeDevice(revokeResponse, revokeRequest)
	if revokeResponse.Code != http.StatusNoContent {
		t.Fatalf("revoke failed: got %d", revokeResponse.Code)
	}

	if frame := readV2DataFrameDeadline(t, pendingA, 2*time.Second); frame == nil || frame.GetClose() == nil {
		t.Fatalf("revoke did not close pending data socket: %+v", frame)
	}
	if frame := readV2DataFrameDeadline(t, activeA, 2*time.Second); frame == nil || frame.GetClose() == nil {
		t.Fatalf("revoke did not close active initiator data socket: %+v", frame)
	}
	if frame := readV2DataFrameDeadline(t, activeB, 2*time.Second); frame == nil || frame.GetClose() == nil {
		t.Fatalf("revoke did not close active counterpart data socket: %+v", frame)
	}
	waitForClose(t, controlA)

	server.hub.mutex.Lock()
	_, controlBStillPresent := server.hub.peers["device-b"]
	server.hub.mutex.Unlock()
	if !controlBStillPresent {
		t.Fatal("revoking device-a unexpectedly removed device-b control admission")
	}

	if conn, response, err := dialControlV2ForRevocation(httpServer.URL, credentialA, 0xa2, privateKeyA); err == nil || conn != nil || response == nil || response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("revoked credential opened a new control socket: status=%v err=%v", responseStatus(response), err)
	}
	identityA := relayDataTestIdentity{credential: credentialA, privateKey: privateKeyA}
	if conn, response, err := dialRelayDataWithIdentity(
		httpServer.URL,
		pending.ReservationID,
		hex.EncodeToString(pending.InitiatorToken),
		identityA,
	); err == nil || conn != nil || response == nil || response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("revoked credential opened a new data socket: status=%v err=%v", responseStatus(response), err)
	}
}
