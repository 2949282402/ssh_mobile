// Relay server composition and route registration.
//
// The device protocol remains under /v1. Administrative HTTP handlers live in
// the admin_* files, while device and hub behavior is kept in their own
// protocol-focused files.

package relay

import (
	"encoding/hex"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type Server struct {
	config          Config
	hub             *hub
	upgrader        websocket.Upgrader
	enrolledDevices map[string]*EnrolledDevice
	revokedDevices  map[string]struct{}
	proofNonces     map[string]map[string]time.Time
	devicesMutex    sync.Mutex
	admin           adminAuthState
	startedAt       time.Time
}

// NewServer 根据给定配置创建仅驻留内存的 Relay 服务。
func NewServer(config Config) *Server {
	if config.Address == "" {
		config.Address = ":8080"
	}
	if config.EnrollmentToken == "" {
		config.EnrollmentToken = hex.EncodeToString(randomBytes(16))
	}
	if len(config.CredentialKey) == 0 {
		config.CredentialKey = randomBytes(32)
	}
	if config.CredentialTTL <= 0 {
		config.CredentialTTL = 24 * time.Hour
	}
	if config.SessionTTL <= 0 {
		config.SessionTTL = 15 * time.Minute
	}
	if config.AdminSessionTTL <= 0 {
		config.AdminSessionTTL = 24 * time.Hour
	}
	if config.MaxConnections <= 0 {
		config.MaxConnections = 2048
	}

	adminPasswordHash := passwordDigest(config.CredentialKey, config.AdminPassword)
	adminConfigured := config.AdminUser != "" && len(config.AdminPassword) >= 12
	config.AdminPassword = ""

	return &Server{
		config:          config,
		hub:             newHub(config),
		upgrader:        websocket.Upgrader{},
		enrolledDevices: make(map[string]*EnrolledDevice),
		revokedDevices:  make(map[string]struct{}),
		proofNonces:     make(map[string]map[string]time.Time),
		admin: adminAuthState{
			user:         config.AdminUser,
			passwordHash: adminPasswordHash,
			configured:   adminConfigured,
			sessions:     make(map[string]time.Time),
		},
		startedAt: time.Now(),
	}
}

// Close 停止 Relay hub，并释放活跃设备连接。
func (s *Server) Close() { s.hub.close() }

// RegisterRoutes 注册公开、管理端和 v1 设备端点。
func (s *Server) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /healthz", s.health)

	// Admin Control Plane。
	mux.HandleFunc("POST /api/admin/v1/auth/login", s.adminLoginHandler)
	mux.HandleFunc("POST /api/admin/v1/auth/logout", s.adminLogoutHandler)
	mux.HandleFunc("GET /api/admin/v1/auth/session", s.adminSessionHandler)
	mux.HandleFunc("GET /api/admin/v1/overview", s.adminAuthMiddleware(s.adminOverview))
	mux.HandleFunc("GET /api/admin/v1/devices", s.adminAuthMiddleware(s.adminDevices))
	mux.HandleFunc("POST /api/admin/v1/devices/{deviceId}/revoke", s.adminAuthMiddleware(s.adminRevokeDevice))
	mux.HandleFunc("GET /api/admin/v1/access/enrollment-token", s.adminAuthMiddleware(s.adminToken))
	mux.HandleFunc("POST /api/admin/v1/access/enrollment-token/rotate", s.adminAuthMiddleware(s.adminRotateToken))

	// Device Plane。
	mux.HandleFunc("POST /v1/devices/enroll", s.enroll)
	mux.HandleFunc("GET /v1/connect", s.connect)
}

// health 提供无需认证的存活检查端点。
func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}
