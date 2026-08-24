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
	if s.config.StorageMode == "mysql" {
		// A process-local mutation would be rolled back by restart and would not
		// reach sibling Relay instances. Durable/shared deployments therefore
		// rotate the deployment secret atomically through RELAY_ENROLLMENT_TOKEN
		// and restart every instance instead of advertising a false rotation.
		writeAdminError(w, http.StatusConflict, adminErrorConflict,
			"Persistent deployments must rotate RELAY_ENROLLMENT_TOKEN and restart all Relay instances.")
		return
	}
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

	ctx, cancel := context.WithTimeout(r.Context(), deviceSecurityOperationTimeout)
	defer cancel()
	// 吊销的 store 部分是单事务（MySQL：device 行 FOR UPDATE + tombstone + 删除），
	// 跨实例与并发 re-enroll 严格串行；分片锁还必须覆盖到本实例所有 admission
	// registry 的断开与事件发布。控制面/数据面会在 upgrade 前取得同一把锁并再次
	// 校验 enrollment，因此 revoke 先取得锁时，新 socket 只能在锁释放后重新校验，
	// 不会从认证成功与 socket 登记之间的 TOCTOU 窗口穿透。
	unlock, locked := s.lockDeviceContext(ctx, deviceID)
	if !locked {
		writeAdminError(w, http.StatusServiceUnavailable, adminErrorInternal, "Revocation operation timed out.")
		return
	}
	outcome, generation, err := s.store.RevokeEnrollment(ctx, deviceID, s.config.CredentialTTL)
	if err != nil {
		unlock()
		writeAdminError(w, http.StatusInternalServerError, adminErrorInternal, "Revocation store is unavailable.")
		return
	}
	switch outcome {
	case revokeNotEnrolled:
		unlock()
		writeAdminError(w, http.StatusNotFound, adminErrorDeviceNotFound, "The requested device was not found.")
		return
	case revokeCapacity:
		unlock()
		writeAdminError(w, http.StatusTooManyRequests, adminErrorResourceLimit, "Revocation store is at capacity; retry after existing revocations expire.")
		return
	}

	// The durable tombstone is authoritative. Close local control/data sockets
	// before any shared-cache work so an unavailable Redis instance cannot let a
	// revoked transfer continue until the request context eventually expires.
	// Control and data sockets have separate registries.  Revoke must close
	// pending data endpoints as well as an active endpoint's counterpart before
	// publishing the durable revocation event.
	s.relayData.closeDevice(deviceID)
	s.hub.disconnectDevice(deviceID)
	s.hub.forgetDiscoveryPublish(deviceID)
	unlock()
	// 广播吊销事件：本实例已直接断开；事件总线是共享实时状态层，供其它连接本共享
	// Redis 的实例收敛同一生命周期决策（设计 §26：本阶段 Relay Control/Data 单实例，
	// 无 Global Control Routing）。
	publishCtx, publishCancel := context.WithTimeout(context.Background(), presenceLeaseTimeout)
	defer publishCancel()
	if err := s.cache.Publish(publishCtx, RelayEvent{
		Type:                 eventDeviceRevoked,
		DeviceID:             deviceID,
		EnrollmentGeneration: generation,
		Time:                 time.Now().UnixMilli(),
	}); err != nil {
		s.logger.Warn("failed to publish revocation event; other instances may not disconnect",
			"device_id", deviceID, "error", err)
	}
	w.WriteHeader(http.StatusNoContent)
}
