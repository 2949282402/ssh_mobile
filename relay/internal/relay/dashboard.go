package relay

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"runtime"
	"time"
)

//go:embed static/*
var staticFS embed.FS

var serverStartTime = time.Now()

type statsResponse struct {
	UptimeSeconds   int64             `json:"uptime_seconds"`
	UptimeFormatted string            `json:"uptime_formatted"`
	ActivePeers     int               `json:"active_peers"`
	ActiveSessions  int               `json:"active_sessions"`
	AllocatedMemMB  float64           `json:"allocated_mem_mb"`
	NumGoroutines   int               `json:"num_goroutines"`
	ServerTime      int64             `json:"server_time"`
	EnrollmentToken string            `json:"enrollment_token"`
	EnrolledCount   int               `json:"enrolled_count"`
	Peers           []peerInfo        `json:"peers"`
	EnrolledDevices []*EnrolledDevice `json:"enrolled_devices"`
}

type peerInfo struct {
	DeviceID   string `json:"device_id"`
	RemoteAddr string `json:"remote_addr"`
}

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
	enrollmentToken := s.config.EnrollmentToken
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
		EnrollmentToken: enrollmentToken,
		EnrolledCount:   enrolledCount,
		Peers:           peerList,
		EnrolledDevices: enrolledList,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func (s *Server) dashboard(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	indexBytes, err := staticFS.ReadFile("static/index.html")
	if err != nil {
		http.Error(w, "Dashboard HTML missing", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(indexBytes)
}

func (s *Server) staticFileHandler() http.Handler {
	sub, err := fs.Sub(staticFS, "static")
	if err != nil {
		panic(err)
	}
	return http.StripPrefix("/static/", http.FileServer(http.FS(sub)))
}
