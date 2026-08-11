// v1 Relay 管理 API；设备数据面仍由 /v1 路由处理。

package relay

import (
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

type hubSnapshot struct {
	ActivePeers    int
	ActiveSessions int
	Online         map[string]string
}

func (h *hub) snapshot() hubSnapshot {
	h.mutex.Lock()
	defer h.mutex.Unlock()

	online := make(map[string]string, len(h.peers))
	for deviceID, peer := range h.peers {
		remoteAddr := ""
		if peer.socket != nil && peer.socket.RemoteAddr() != nil {
			remoteAddr = peer.socket.RemoteAddr().String()
		}
		online[deviceID] = remoteAddr
	}
	return hubSnapshot{
		ActivePeers:    len(h.peers),
		ActiveSessions: len(h.transferSessions),
		Online:         online,
	}
}

func (s *Server) adminOverview(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(s.adminOverviewSnapshot())
}

func (s *Server) adminOverviewSnapshot() adminOverviewResponse {
	hubState := s.hub.snapshot()
	s.devicesMutex.Lock()
	enrolled := len(s.enrolledDevices)
	s.devicesMutex.Unlock()

	var memory runtime.MemStats
	runtime.ReadMemStats(&memory)

	return adminOverviewResponse{
		ServerTime:    time.Now().Unix(),
		UptimeSeconds: int64(time.Since(s.startedAt).Seconds()),
		Devices: adminDeviceStat{
			Enrolled: enrolled,
			Online:   hubState.ActivePeers,
		},
		Relay: adminRelayStat{
			ActiveTransfers: hubState.ActiveSessions,
		},
		Runtime: adminRuntimeStat{
			AllocatedMemMB: float64(memory.Alloc) / 1024 / 1024,
			Goroutines:     runtime.NumGoroutine(),
		},
	}
}

func (s *Server) adminDevices(w http.ResponseWriter, _ *http.Request) {
	items := s.adminDeviceSnapshot()
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(adminDevicesResponse{Items: items, Total: len(items)})
}

func (s *Server) adminDeviceSnapshot() []adminDevice {
	hubState := s.hub.snapshot()
	s.devicesMutex.Lock()
	items := make([]adminDevice, 0, len(s.enrolledDevices))
	for _, enrolled := range s.enrolledDevices {
		items = append(items, adminDevice{
			DeviceID:             enrolled.DeviceID,
			Platform:             enrolled.Platform,
			ProtocolVersion:      enrolled.ProtocolVersion,
			EnrolledAt:           enrolled.EnrolledAt.UTC().Format(time.RFC3339Nano),
			Online:               hasOnlinePeer(hubState, enrolled.DeviceID),
			RemoteAddr:           hubState.Online[enrolled.DeviceID],
			PublicKeyFingerprint: publicKeyFingerprint(enrolled.PublicKey),
		})
	}
	s.devicesMutex.Unlock()
	sort.Slice(items, func(i, j int) bool {
		return items[i].DeviceID < items[j].DeviceID
	})
	return items
}

func hasOnlinePeer(snapshot hubSnapshot, deviceID string) bool {
	_, online := snapshot.Online[deviceID]
	return online
}

func publicKeyFingerprint(encodedPublicKey string) string {
	publicKey, err := base64.RawURLEncoding.DecodeString(encodedPublicKey)
	if err != nil {
		return ""
	}
	digest := sha256.Sum256(publicKey)
	return "SHA256:" + base64.RawStdEncoding.EncodeToString(digest[:])
}
