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
	revokedDevices  map[string]revokedDevice
	proofNonces     map[string]map[string]time.Time
	devicesMutex    sync.Mutex
	admin           adminAuthState
	startedAt       time.Time
}

// NewServer 根据给定配置创建仅驻留内存的 Relay 服务。
func NewServer(config Config) *Server {
	config = withConfigDefaults(config)
	if config.EnrollmentToken == "" {
		config.EnrollmentToken = hex.EncodeToString(randomBytes(16))
	}
	if len(config.CredentialKey) == 0 {
		config.CredentialKey = randomBytes(32)
	}

	adminPasswordHash := passwordDigest(config.CredentialKey, config.AdminPassword)
	adminConfigured := config.AdminUser != "" && len(config.AdminPassword) >= 12
	config.AdminPassword = ""

	return &Server{
		config:          config,
		hub:             newHub(config),
		upgrader:        websocket.Upgrader{},
		enrolledDevices: make(map[string]*EnrolledDevice),
		revokedDevices:  make(map[string]revokedDevice),
		proofNonces:     make(map[string]map[string]time.Time),
		admin: adminAuthState{
			user:          config.AdminUser,
			passwordHash:  adminPasswordHash,
			configured:    adminConfigured,
			sessions:      make(map[string]time.Time),
			loginAttempts: make(map[string]adminLoginAttempt),
		},
		startedAt: time.Now(),
	}
}

// Close 停止 Relay hub，并释放活跃设备连接。
func (s *Server) Close() { s.hub.close() }

// RegisterRoutes 注册公开、管理端和 v1 设备端点。
func (s *Server) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /healthz", s.health)

	admin := func(next http.HandlerFunc) http.HandlerFunc {
		return adminResponseHeaders(next)
	}
	adminStateChange := func(next http.HandlerFunc) http.HandlerFunc {
		return adminResponseHeaders(adminStateChangeMiddleware(next))
	}
	adminAuth := func(next http.HandlerFunc) http.HandlerFunc {
		return adminResponseHeaders(s.adminAuthMiddleware(next))
	}
	adminAuthStateChange := func(next http.HandlerFunc) http.HandlerFunc {
		return adminResponseHeaders(adminStateChangeMiddleware(s.adminAuthMiddleware(next)))
	}

	// Admin Control Plane。
	mux.HandleFunc("POST /api/admin/v1/auth/login", adminStateChange(s.adminLoginHandler))
	mux.HandleFunc("POST /api/admin/v1/auth/logout", adminStateChange(s.adminLogoutHandler))
	mux.HandleFunc("GET /api/admin/v1/auth/session", admin(s.adminSessionHandler))
	mux.HandleFunc("GET /api/admin/v1/overview", adminAuth(s.adminOverview))
	mux.HandleFunc("GET /api/admin/v1/devices", adminAuth(s.adminDevices))
	mux.HandleFunc("POST /api/admin/v1/devices/{deviceId}/revoke", adminAuthStateChange(s.adminRevokeDevice))
	mux.HandleFunc("GET /api/admin/v1/access/enrollment-token", adminAuth(s.adminToken))
	mux.HandleFunc("POST /api/admin/v1/access/enrollment-token/rotate", adminAuthStateChange(s.adminRotateToken))

	// Device Plane。
	mux.HandleFunc("POST /v1/devices/enroll", s.enroll)
	mux.HandleFunc("POST /v1/devices/refresh", s.refresh)
	mux.HandleFunc("GET /v1/connect", s.connect)
}

// health 提供无需认证的存活检查端点。
func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}
