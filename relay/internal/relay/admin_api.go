// v1 Relay 管理 API；设备数据面仍由 server.go 的 v1 路由处理。

package relay

import (
	"encoding/json"
	"fmt"
	"net/http"
	"runtime"
	"time"
)

var serverStartTime = time.Now()

// statsResponse 是管理员控制台使用的当前运行统计。
type statsResponse struct {
	UptimeSeconds   int64             `json:"uptime_seconds"`
	UptimeFormatted string            `json:"uptime_formatted"`
	ActivePeers     int               `json:"active_peers"`
	ActiveSessions  int               `json:"active_sessions"`
	AllocatedMemMB  float64           `json:"allocated_mem_mb"`
	NumGoroutines   int               `json:"num_goroutines"`
	ServerTime      int64             `json:"server_time"`
	EnrolledCount   int               `json:"enrolled_count"`
	Peers           []peerInfo        `json:"peers"`
	EnrolledDevices []*EnrolledDevice `json:"enrolled_devices"`
}

// peerInfo 描述一个当前在线的 Relay 设备连接。
type peerInfo struct {
	DeviceID   string `json:"device_id"`
	RemoteAddr string `json:"remote_addr"`
}

// apiStats 返回经过管理员认证的运行统计和设备列表。
func (s *Server) apiStats(w http.ResponseWriter, _ *http.Request) {
	s.hub.mutex.Lock()
	activePeers := len(s.hub.peers)
	activeSessions := len(s.hub.sessions)
	peerList := make([]peerInfo, 0, activePeers)
	for id, p := range s.hub.peers {
		addr := ""
		if p.socket != nil {
			addr = p.socket.RemoteAddr().String()
		}
		peerList = append(peerList, peerInfo{
			DeviceID:   id,
			RemoteAddr: addr,
		})
	}
	s.hub.mutex.Unlock()

	s.devicesMutex.Lock()
	enrolledCount := len(s.enrolledDevices)
	enrolledList := make([]*EnrolledDevice, 0, enrolledCount)
	for _, dev := range s.enrolledDevices {
		enrolledList = append(enrolledList, dev)
	}
	s.devicesMutex.Unlock()

	var m runtime.MemStats
	runtime.ReadMemStats(&m)

	uptime := time.Since(serverStartTime)
	days := int(uptime.Hours()) / 24
	hours := int(uptime.Hours()) % 24
	mins := int(uptime.Minutes()) % 60
	secs := int(uptime.Seconds()) % 60
	uptimeStr := ""
	if days > 0 {
		uptimeStr = fmt.Sprintf("%dd ", days)
	}
	uptimeStr += fmt.Sprintf("%02dh %02dm %02ds", hours, mins, secs)

	resp := statsResponse{
		UptimeSeconds:   int64(uptime.Seconds()),
		UptimeFormatted: uptimeStr,
		ActivePeers:     activePeers,
		ActiveSessions:  activeSessions,
		AllocatedMemMB:  float64(m.Alloc) / 1024 / 1024,
		NumGoroutines:   runtime.NumGoroutine(),
		ServerTime:      time.Now().Unix(),
		EnrolledCount:   enrolledCount,
		Peers:           peerList,
		EnrolledDevices: enrolledList,
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

// apiToken 返回仅供管理员 Access 页面使用的当前 enrollment token。
func (s *Server) apiToken(w http.ResponseWriter, _ *http.Request) {
	s.devicesMutex.Lock()
	token := s.config.EnrollmentToken
	s.devicesMutex.Unlock()

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"enrollment_token": token,
	})
}
