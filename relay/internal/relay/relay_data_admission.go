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
	retries      *relayDataRegistry
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
		if a.retries == nil {
			return Reservation{}, 0, relayDataAdmissionMissing
		}
		res, ok = a.retries.retryReservation(reservationID)
		if !ok {
			return Reservation{}, 0, relayDataAdmissionMissing
		}
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
		writeNetworkErrorRetry(w, http.StatusNotFound, relayErrorInvalidArgument,
			"Relay data reservation is invalid.", "connect_relay_data", "", retryNoRetry, 0)
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
	admission, admissionCode, admitted := s.admitAuthenticatedDevice(r.Context(), claims, publicKey)
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
		if admission != nil {
			admission.release()
		}
	}()
	ctx, cancel := context.WithTimeout(admission.ctx, presenceLeaseTimeout)
	res, role, reservationAdmission := (relayDataAdmission{reservations: s.cache, retries: s.relayData}).authorize(
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
		writeNetworkErrorRetry(w, http.StatusNotFound, relayErrorInvalidArgument,
			"Relay data reservation is unavailable.", "connect_relay_data", "", retryNoRetry, 0)
		return
	case relayDataAdmissionForbidden:
		writeNetworkErrorRetry(w, http.StatusUnauthorized, relayErrorAuthenticationFailed,
			"Relay data reservation authentication failed.", "connect_relay_data", "", retryNoRetry, 0)
		return
	case relayDataAdmissionAccepted:
	}
	// Reserve upgraded-without-Connect capacity before emitting HTTP 101. This
	// closes the race where many authenticated requests all upgrade first and
	// only become visible to the registry afterwards.
	upgradeLease, upgradeAdmission := s.relayData.beginUpgrade(claims.DeviceID, claims.EnrollmentGeneration)
	switch upgradeAdmission {
	case relayDataUpgradeClosed:
		writeNetworkErrorRetry(w, http.StatusServiceUnavailable, relayErrorRelayError,
			"Relay data service is shutting down.", "connect_relay_data", "", retryWithBackoff, 0)
		return
	case relayDataUpgradeCapacity:
		writeNetworkErrorRetry(w, http.StatusTooManyRequests, relayErrorRelayError,
			"Relay data connection capacity is exhausted.", "connect_relay_data", "", retryWithBackoff, 0)
		return
	case relayDataUpgradeAccepted:
	}
	defer upgradeLease.release()
	// 不按名义 ExpiresAtMs 做升级准入：滑动窗口续期（RenewReservation/touch）只滑动
	// 存储 TTL，从不回写 ExpiresAtMs，因此晚加入的端点即使名义到期已过、只要存储键仍
	// 存活（GetReservation ok）就必须被接受。GetReservation 的 ok 结果已编码滑动窗口
	// 活性（memoryStore 按滑动的 entry.expiresAt 剪除，redisStore 依赖滑动的 Redis TTL）。
	connection, err := s.upgradeWithinContext(admission.ctx, w, r)
	if err != nil {
		return
	}
	// 只有首帧 RelayDataConnect 通过校验后才进入 pending/active pair；Upgrade 后、
	// Connect 前则由同一预占 slot 转换成 upgradeRefs，以便 revoke/shutdown 关闭。
	rc := newRelayDataConn(s.relayData, res, connection, s.config, s.cache, claims.DeviceID, role, claims.EnrollmentGeneration)
	if !s.relayData.stageEndpoint(upgradeLease, rc) {
		_ = connection.Close()
		return
	}
	_, enrollmentCurrent := s.enrollmentClaimsCurrent(admission.ctx, claims, publicKey)
	if !enrollmentCurrent || !s.relayData.activateEndpoint(rc) {
		rc.sendCloseAndShutdown(2, "device enrollment changed during relay data admission")
		return
	}
	admission.release()
	admission = nil
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

// validRelayToken 只从 X-Relay-Token header 读取 hex 编码的 reservation token，
// 并校验它匹配 A 或 B 任一端；任何 query token 都 fail closed。
func validRelayToken(r *http.Request, res Reservation) bool {
	return validRelayTokenForRole(r, res, relayDataRoleInitiator) ||
		validRelayTokenForRole(r, res, relayDataRoleResponder)
}

func validRelayTokenForRole(r *http.Request, res Reservation, role relayDataRole) bool {
	// Reservation tokens are credentials. Reject URL query transport because
	// URLs are routinely retained by proxies, access logs, and browser history.
	if r.URL.Query().Get("token") != "" {
		return false
	}
	token := r.Header.Get("X-Relay-Token")
	if token == "" {
		return false
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
