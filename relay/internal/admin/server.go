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
	mux.HandleFunc(RouteHealthz, s.health)

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
	mux.HandleFunc(RouteAuthLogin, adminStateChange(s.adminLoginHandler))
	mux.HandleFunc(RouteAuthLogout, adminStateChange(s.adminLogoutHandler))
	mux.HandleFunc(RouteAuthSession, admin(s.adminSessionHandler))

	// Management Endpoints
	mux.HandleFunc(RouteOverview, adminAuth(s.overviewHandler))
	mux.HandleFunc(RouteDevices, adminAuth(s.devicesHandler))
	mux.HandleFunc(RouteRevokeDevice, adminAuthStateChange(s.revokeHandler))
	mux.HandleFunc(RouteEnrollmentToken, adminAuth(s.tokenHandler))
	mux.HandleFunc(RouteRotateToken, adminAuthStateChange(s.rotateTokenHandler))
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
