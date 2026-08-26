// Admin backend HTTP server and routing.

package admin

import (
	"net/http"
	"sync"
	"time"
)

// Server represents the standalone Admin backend HTTP service.
type Server struct {
	config       Config
	admin        adminAuthState
	sessionStore SessionStore
	relayClient  RelayManagementClient
	startedAt    time.Time
	closeOnce    sync.Once
}

// NewServer creates a new Admin backend server with the supplied configuration.
func NewServer(config Config) *Server {
	return NewServerWithClient(config, nil)
}

// NewServerWithClient allows injecting a custom RelayManagementClient (e.g. in tests).
func NewServerWithClient(config Config, client RelayManagementClient) *Server {
	config = withConfigDefaults(config)
	if len(config.AuthKey) == 0 {
		config.AuthKey = randomBytes(32)
	}

	adminConfigured := config.AdminUser != "" && len(config.AdminPassword) >= 12
	adminHash := passwordDigest(config.AuthKey, config.AdminPassword)
	// Clear plaintext password from memory
	config.AdminPassword = ""

	if client == nil {
		client = NewRelayManagementClient(config.RelayURL, config.RelayInternalToken)
	}

	return &Server{
		config: config,
		admin: adminAuthState{
			user:          config.AdminUser,
			passwordHash:  adminHash,
			configured:    adminConfigured,
			loginAttempts: make(map[string]adminLoginAttempt),
		},
		sessionStore: newMemorySessionStore(config.MaxSessions),
		relayClient:  client,
		startedAt:    time.Now(),
	}
}

// RegisterRoutes registers the Admin service HTTP endpoints.
func (s *Server) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /healthz", s.health)

	admin := func(next http.HandlerFunc) http.HandlerFunc {
		return s.adminResponseHeaders(next)
	}
	adminStateChange := func(next http.HandlerFunc) http.HandlerFunc {
		return s.adminResponseHeaders(s.adminStateChangeMiddleware(next))
	}
	adminAuth := func(next http.HandlerFunc) http.HandlerFunc {
		return s.adminResponseHeaders(s.adminAuthMiddleware(next))
	}
	adminAuthStateChange := func(next http.HandlerFunc) http.HandlerFunc {
		return s.adminResponseHeaders(s.adminStateChangeMiddleware(s.adminAuthMiddleware(next)))
	}

	// Auth Endpoints
	mux.HandleFunc("POST /api/admin/v1/auth/login", adminStateChange(s.adminLoginHandler))
	mux.HandleFunc("POST /api/admin/v1/auth/logout", adminStateChange(s.adminLogoutHandler))
	mux.HandleFunc("GET /api/admin/v1/auth/session", admin(s.adminSessionHandler))

	// Management Endpoints
	mux.HandleFunc("GET /api/admin/v1/overview", adminAuth(s.overviewHandler))
	mux.HandleFunc("GET /api/admin/v1/devices", adminAuth(s.devicesHandler))
	mux.HandleFunc("POST /api/admin/v1/devices/{deviceId}/revoke", adminAuthStateChange(s.revokeHandler))
	mux.HandleFunc("GET /api/admin/v1/access/enrollment-token", adminAuth(s.tokenHandler))
	mux.HandleFunc("POST /api/admin/v1/access/enrollment-token/rotate", adminAuthStateChange(s.rotateTokenHandler))
}

// health provides an independent process liveness check that does NOT depend on Relay.
func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}

// Close gracefully stops the Admin backend service and releases held resources.
func (s *Server) Close() error {
	s.closeOnce.Do(func() {
		if s.sessionStore != nil {
			_ = s.sessionStore.Close()
		}
	})
	return nil
}
