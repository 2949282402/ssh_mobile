package relay

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"time"
)

func (s *Server) adminToken(w http.ResponseWriter, _ *http.Request) {
	s.tokenMutex.Lock()
	token := s.config.EnrollmentToken
	s.tokenMutex.Unlock()

	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"enrollment_token": token,
	})
}

func (s *Server) adminRotateToken(w http.ResponseWriter, _ *http.Request) {
	newToken := hex.EncodeToString(randomBytes(16))
	s.tokenMutex.Lock()
	s.config.EnrollmentToken = newToken
	s.tokenMutex.Unlock()

	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"enrollment_token": newToken,
	})
}

func (s *Server) adminRevokeDevice(w http.ResponseWriter, r *http.Request) {
	deviceID := r.PathValue("deviceId")
	if deviceID == "" || len(deviceID) > 128 {
		writeAdminError(w, http.StatusBadRequest, adminErrorInvalidRequest, "Device identity is invalid.")
		return
	}

	ctx := r.Context()
	// 吊销是跨 store/cache 调用的复合单元，用该设备的 per-device 分片锁串行化，
	// 避免与并发 re-enroll 交错（读取后删除会误删新 enrollment）。
	unlock := s.lockDevice(deviceID)
	defer unlock()
	enrolled, getErr := s.store.GetEnrollment(ctx, deviceID)
	if getErr != nil || enrolled == nil {
		writeAdminError(w, http.StatusNotFound, adminErrorDeviceNotFound, "The requested device was not found.")
		return
	}
	// The revoked device's current credential was issued at enrollment and
	// expires CredentialTTL later; the tombstone only needs to outlive that.
	// Guard the degenerate zero EnrolledAt so a fresh, conservative bound is
	// used instead of a tombstone that is already expired.
	credentialExpiry := enrolled.EnrolledAt.Add(s.config.CredentialTTL)
	if enrolled.EnrolledAt.IsZero() {
		credentialExpiry = time.Now().Add(s.config.CredentialTTL)
	}
	recorded, revokeErr := s.store.RecordRevocation(ctx, deviceID, credentialExpiry)
	if revokeErr != nil {
		writeAdminError(w, http.StatusInternalServerError, adminErrorInternal, "Revocation store is unavailable.")
		return
	}
	if !recorded {
		writeAdminError(w, http.StatusTooManyRequests, adminErrorResourceLimit, "Revocation store is at capacity; retry after existing revocations expire.")
		return
	}
	if err := s.store.RemoveEnrollment(ctx, deviceID); err != nil {
		// 墓碑已落但 enrollment 删除失败：设备仍在 devices 表，refresh 会续发凭据。
		// 返回 500 让操作员知道吊销未完整落地，而不是假 204。
		writeAdminError(w, http.StatusInternalServerError, adminErrorInternal, "Revocation could not remove the device enrollment.")
		return
	}
	_ = s.cache.ClearDeviceNonces(ctx, deviceID)

	s.hub.disconnectDevice(deviceID)
	// 广播吊销事件：本实例已直接断开，其它实例据此断开该设备（Phase 4 多实例）。
	if err := s.cache.Publish(context.Background(), RelayEvent{
		Type:     eventDeviceRevoked,
		DeviceID: deviceID,
		Time:     time.Now().UnixMilli(),
	}); err != nil {
		s.logger.Warn("failed to publish revocation event; other instances may not disconnect",
			"device_id", deviceID, "error", err)
	}
	w.WriteHeader(http.StatusNoContent)
}
