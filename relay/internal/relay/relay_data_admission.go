// Authenticated HTTP admission for reservation-scoped Relay Data sockets.

package relay

import (
	"context"
	"crypto/hmac"
	"encoding/hex"
	"net/http"
	"strings"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

type relayReservationLookup interface {
	GetReservation(context.Context, string) (Reservation, bool, error)
}

type relayDataAdmissionStatus uint8

const (
	relayDataAdmissionAccepted relayDataAdmissionStatus = iota
	relayDataAdmissionUnavailable
	relayDataAdmissionMissing
	relayDataAdmissionForbidden
)

type relayDataAdmission struct {
	reservations relayReservationLookup
}

// authorize binds the authenticated device, reservation role, and exact local
// token before WebSocket upgrade. The first binary frame repeats this binding;
// the registry then consumes the role slot exactly once.
func (a relayDataAdmission) authorize(ctx context.Context, r *http.Request, reservationID, deviceID string) (Reservation, relayDataRole, relayDataAdmissionStatus) {
	res, ok, err := a.reservations.GetReservation(ctx, reservationID)
	if err != nil {
		return Reservation{}, 0, relayDataAdmissionUnavailable
	}
	if !ok {
		return Reservation{}, 0, relayDataAdmissionMissing
	}
	role, roleOK := relayDataRoleForDevice(res, deviceID)
	if !roleOK || !validRelayTokenForRole(r, res, role) {
		return Reservation{}, 0, relayDataAdmissionForbidden
	}
	return res, role, relayDataAdmissionAccepted
}

// ---------------------------------------------------------------------------
// HTTP：GET /v2/relay/{reservation_id}
// ---------------------------------------------------------------------------

// connectRelayData 处理 /v2/relay/{reservation_id} 升级。先完成与控制面相同的
// authenticatedRequest，再按 authenticated device -> reservation role -> role token
// 绑定校验 query/header token；首帧 RelayDataConnect 会再次执行同一绑定校验。
func (s *Server) connectRelayData(w http.ResponseWriter, r *http.Request) {
	reservationID := r.PathValue("reservation_id")
	if !validReservationID(reservationID) {
		http.Error(w, "invalid reservation id", http.StatusNotFound)
		return
	}
	// Authenticate before touching reservation state.  An unauthenticated caller
	// must not be able to distinguish an existing reservation from a missing one.
	claims, publicKey, code, authenticated := s.authenticatedRequest(r)
	if !authenticated {
		retry := retryUnspecified
		if code == relayErrorCredentialExpired {
			retry = retryRefreshCredentialThenRetry
		}
		writeNetworkErrorRetry(w, http.StatusUnauthorized, code,
			"Relay data-plane authentication failed.", "connect_relay_data", "", retry, 0)
		return
	}
	unlockAdmission, admissionCode, admitted := s.admitAuthenticatedDevice(r.Context(), claims, publicKey)
	if !admitted {
		retry := retryUnspecified
		if admissionCode == relayErrorCredentialExpired {
			retry = retryRefreshCredentialThenRetry
		}
		writeNetworkErrorRetry(w, http.StatusUnauthorized, admissionCode,
			"Relay data-plane authentication failed.", "connect_relay_data", "", retry, 0)
		return
	}
	// Hold the device admission lock through reservation/token validation,
	// websocket upgrade, and upgrade-registry insertion only. The data socket is
	// long-lived, so retaining the lock for its whole lifetime would delay
	// revoke/re-enroll indefinitely; after trackUpgrade, revoke can find and
	// close this endpoint directly.
	defer func() {
		if unlockAdmission != nil {
			unlockAdmission()
		}
	}()
	ctx, cancel := context.WithTimeout(r.Context(), presenceLeaseTimeout)
	res, role, reservationAdmission := (relayDataAdmission{reservations: s.cache}).authorize(
		ctx,
		r,
		reservationID,
		claims.DeviceID,
	)
	cancel()
	switch reservationAdmission {
	case relayDataAdmissionUnavailable:
		writeNetworkErrorRetry(w, http.StatusServiceUnavailable, relayErrorUnspecified,
			"Relay data reservation lookup failed.", "connect_relay_data", "", retryUnspecified, 0)
		return
	case relayDataAdmissionMissing:
		http.Error(w, "reservation not found", http.StatusNotFound)
		return
	case relayDataAdmissionForbidden:
		http.Error(w, "invalid reservation token", http.StatusUnauthorized)
		return
	case relayDataAdmissionAccepted:
	}
	// 不按名义 ExpiresAtMs 做升级准入：滑动窗口续期（RenewReservation/touch）只滑动
	// 存储 TTL，从不回写 ExpiresAtMs，因此晚加入的端点即使名义到期已过、只要存储键仍
	// 存活（GetReservation ok）就必须被接受。GetReservation 的 ok 结果已编码滑动窗口
	// 活性（memoryStore 按滑动的 entry.expiresAt 剪除，redisStore 依赖滑动的 Redis TTL）。
	connection, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	// 不在升级阶段登记：只有首帧 RelayDataConnect 通过校验后才进入 registry（避免
	// 把自身当成等待对端）。未发 Connect 的已升级连接不占 pending 容量，但仍
	// 由 upgradeRefs 追踪，以便 explicit revoke 立即关闭它。
	rc := newRelayDataConn(&s.relayData, res, connection, s.config, s.cache, claims.DeviceID, role)
	s.relayData.trackUpgrade(rc)
	unlockAdmission()
	unlockAdmission = nil
	go rc.write()
	go rc.read()
}

func relayDataRoleForDevice(res Reservation, deviceID string) (relayDataRole, bool) {
	if deviceID == "" || res.InitiatorDeviceID == res.ResponderDeviceID {
		return 0, false
	}
	switch deviceID {
	case res.InitiatorDeviceID:
		return relayDataRoleInitiator, true
	case res.ResponderDeviceID:
		return relayDataRoleResponder, true
	default:
		return 0, false
	}
}

// validReservationID 校验 reservation_id 是 16-byte hex、32 个小写字符。
func validReservationID(id string) bool {
	if len(id) != v2.RESERVATION_ID_HEX_CHARS {
		return false
	}
	if id != strings.ToLower(id) {
		return false
	}
	_, err := hex.DecodeString(id)
	return err == nil
}

// validRelayToken 从 query (?token=) 或 header (X-Relay-Token) 读取 hex 编码的
// reservation token，并校验它匹配 A 或 B 任一端的 token。
func validRelayToken(r *http.Request, res Reservation) bool {
	return validRelayTokenForRole(r, res, relayDataRoleInitiator) ||
		validRelayTokenForRole(r, res, relayDataRoleResponder)
}

func validRelayTokenForRole(r *http.Request, res Reservation, role relayDataRole) bool {
	queryToken := r.URL.Query().Get("token")
	headerToken := r.Header.Get("X-Relay-Token")
	if queryToken == "" && headerToken == "" {
		return false
	}
	if queryToken != "" && headerToken != "" && queryToken != headerToken {
		return false
	}
	token := queryToken
	if token == "" {
		token = headerToken
	}
	raw, err := hex.DecodeString(token)
	if err != nil {
		return false
	}
	var expected []byte
	switch role {
	case relayDataRoleInitiator:
		expected = res.InitiatorToken
	case relayDataRoleResponder:
		expected = res.ResponderToken
	default:
		return false
	}
	return len(raw) == len(expected) && hmac.Equal(raw, expected)
}
