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
	// 吊销的 store 部分是单事务（MySQL：device 行 FOR UPDATE + tombstone + 删除），
	// 跨实例与并发 re-enroll 严格串行，不需要进程内锁兜底原子性；分片锁仍用于把
	// 同设备在本实例内的 store 调用与 cache 清理 / hub 断开 / 事件发布串行化。
	unlock := s.lockDevice(deviceID)
	defer unlock()
	outcome, err := s.store.RevokeEnrollment(ctx, deviceID, s.config.CredentialTTL)
	if err != nil {
		writeAdminError(w, http.StatusInternalServerError, adminErrorInternal, "Revocation store is unavailable.")
		return
	}
	switch outcome {
	case revokeNotEnrolled:
		writeAdminError(w, http.StatusNotFound, adminErrorDeviceNotFound, "The requested device was not found.")
		return
	case revokeCapacity:
		writeAdminError(w, http.StatusTooManyRequests, adminErrorResourceLimit, "Revocation store is at capacity; retry after existing revocations expire.")
		return
	}

	_ = s.cache.ClearDeviceNonces(ctx, deviceID)

	s.hub.disconnectDevice(deviceID)
	// 广播吊销事件：本实例已直接断开；事件总线是共享实时状态层，供其它连接本共享
	// Redis 的实例收敛同一生命周期决策（设计 §26：本阶段 Relay Control/Data 单实例，
	// 无 Global Control Routing）。
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
