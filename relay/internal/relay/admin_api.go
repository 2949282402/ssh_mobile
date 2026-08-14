// v1 Relay 管理 API；设备数据面仍由 /v1 路由处理。

package relay

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"runtime"
	"sort"
	"time"
)

type adminOverviewResponse struct {
	ServerTime    int64            `json:"server_time"`
	UptimeSeconds int64            `json:"uptime_seconds"`
	Devices       adminDeviceStat  `json:"devices"`
	Relay         adminRelayStat   `json:"relay"`
	Runtime       adminRuntimeStat `json:"runtime"`
}

type adminDeviceStat struct {
	Enrolled int `json:"enrolled"`
	Online   int `json:"online"`
}

type adminRelayStat struct {
	ActiveTransfers int `json:"active_transfers"`
}

type adminRuntimeStat struct {
	AllocatedMemMB float64 `json:"allocated_mem_mb"`
	Goroutines     int     `json:"goroutines"`
}

type adminDevicesResponse struct {
	Items []adminDevice `json:"items"`
	Total int           `json:"total"`
}

type adminDevice struct {
	DeviceID             string `json:"device_id"`
	Platform             string `json:"platform"`
	ProtocolVersion      uint32 `json:"protocol_version"`
	EnrolledAt           string `json:"enrolled_at"`
	Online               bool   `json:"online"`
	RemoteAddr           string `json:"remote_addr"`
	PublicKeyFingerprint string `json:"public_key_fingerprint"`
}

// hubSnapshot 只带管理端消费的本地 hub 数据。在线状态与 RemoteAddr 一律来自
// presence 租约（GetPresences），本地 peer 表不参与 admin 视图——它在多实例部署
// 下只反映本实例，跨实例设备会显示为空白地址。
type hubSnapshot struct {
	ActiveSessions int
}

func (h *hub) snapshot() hubSnapshot {
	h.mutex.Lock()
	defer h.mutex.Unlock()
	return hubSnapshot{ActiveSessions: len(h.transferSessions)}
}

func (s *Server) adminOverview(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	snapshot, err := s.adminOverviewSnapshot()
	if err != nil {
		writeAdminError(w, http.StatusInternalServerError, adminErrorInternal, "Device storage is unavailable.")
		return
	}
	_ = json.NewEncoder(w).Encode(snapshot)
}

func (s *Server) adminOverviewSnapshot() (adminOverviewResponse, error) {
	hubState := s.hub.snapshot()
	s.devicesMutex.Lock()
	enrolledList, err := s.store.ListEnrollments(context.Background())
	s.devicesMutex.Unlock()
	if err != nil {
		return adminOverviewResponse{}, err
	}
	enrolled := len(enrolledList)
	// 一次批量查询替代逐设备 GetPresence（N+1 → 1）。
	deviceIDs := make([]string, 0, enrolled)
	for _, device := range enrolledList {
		deviceIDs = append(deviceIDs, device.DeviceID)
	}
	presences, _ := s.cache.GetPresences(context.Background(), deviceIDs)
	online := len(presences)

	var memory runtime.MemStats
	runtime.ReadMemStats(&memory)

	return adminOverviewResponse{
		ServerTime:    time.Now().Unix(),
		UptimeSeconds: int64(time.Since(s.startedAt).Seconds()),
		Devices: adminDeviceStat{
			Enrolled: enrolled,
			Online:   online,
		},
		Relay: adminRelayStat{
			ActiveTransfers: hubState.ActiveSessions,
		},
		Runtime: adminRuntimeStat{
			AllocatedMemMB: float64(memory.Alloc) / 1024 / 1024,
			Goroutines:     runtime.NumGoroutine(),
		},
	}, nil
}

func (s *Server) adminDevices(w http.ResponseWriter, _ *http.Request) {
	items, err := s.adminDeviceSnapshot()
	if err != nil {
		writeAdminError(w, http.StatusInternalServerError, adminErrorInternal, "Device storage is unavailable.")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(adminDevicesResponse{Items: items, Total: len(items)})
}

func (s *Server) adminDeviceSnapshot() ([]adminDevice, error) {
	s.devicesMutex.Lock()
	enrolledList, err := s.store.ListEnrollments(context.Background())
	s.devicesMutex.Unlock()
	if err != nil {
		return nil, err
	}
	// 一次批量查询替代逐设备 GetPresence（N+1 → 1）。Online 与 RemoteAddr 都取
	// 自 presence 租约：跨实例部署下设备连在其它实例时，租约里的地址才是它真实
	// 所在连接的地址（本地 peer 表只反映本实例，会显示为空）。
	deviceIDs := make([]string, 0, len(enrolledList))
	for _, enrolled := range enrolledList {
		deviceIDs = append(deviceIDs, enrolled.DeviceID)
	}
	presences, _ := s.cache.GetPresences(context.Background(), deviceIDs)
	items := make([]adminDevice, 0, len(enrolledList))
	for _, enrolled := range enrolledList {
		presence, online := presences[enrolled.DeviceID]
		items = append(items, adminDevice{
			DeviceID:             enrolled.DeviceID,
			Platform:             enrolled.Platform,
			ProtocolVersion:      enrolled.ProtocolVersion,
			EnrolledAt:           enrolled.EnrolledAt.UTC().Format(time.RFC3339Nano),
			Online:               online,
			RemoteAddr:           presence.RemoteAddr,
			PublicKeyFingerprint: publicKeyFingerprint(enrolled.PublicKey),
		})
	}
	sort.Slice(items, func(i, j int) bool {
		return items[i].DeviceID < items[j].DeviceID
	})
	return items, nil
}

func publicKeyFingerprint(encodedPublicKey string) string {
	publicKey, err := base64.RawURLEncoding.DecodeString(encodedPublicKey)
	if err != nil {
		return ""
	}
	digest := sha256.Sum256(publicKey)
	return "SHA256:" + base64.RawStdEncoding.EncodeToString(digest[:])
}
