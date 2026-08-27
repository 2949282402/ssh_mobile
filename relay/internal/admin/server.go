// Admin backend HTTP server and routing.

package admin

import (
	"net/http"
	"sync"
	"time"

	"github.com/ssh-mobile/relay/internal/telemetry"
)

// Server represents the standalone Admin backend HTTP service.
type Server struct {
	config           Config
	admin            adminAuthState
	sessionStore     SessionStore
	relayClient      RelayManagementClient
	telemetryService *telemetry.Service
	telemetryHandler *telemetry.Handler
	telemetryWorker  *telemetry.RetentionWorker
	startedAt        time.Time
	closeOnce        sync.Once
}

// NewServer creates a new Admin backend server with the supplied configuration.
func NewServer(config Config) *Server {
	return NewServerWithClient(config, nil)
}

// NewServerWithClient allows injecting a custom RelayManagementClient (e.g. in tests).
func NewServerWithClient(config Config, client RelayManagementClient) *Server {
	return NewServerWithClientAndTelemetry(config, client, nil)
}

// NewServerWithClientAndTelemetry allows injecting custom RelayManagementClient and TelemetryService.
func NewServerWithClientAndTelemetry(config Config, client RelayManagementClient, telemetryService *telemetry.Service) *Server {
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

	if telemetryService == nil {
		catalog := telemetry.DefaultCatalog()
		store := telemetry.NewMemoryStore(catalog)
		telemetryService = telemetry.NewService(store, catalog, &telemetry.NoopRedisCache{})
	}

	telemetryHandler := telemetry.NewHandler(telemetryService)
	telemetryWorker := telemetry.NewRetentionWorker(telemetryService, 1*time.Hour)
	telemetryWorker.Start()

	return &Server{
		config: config,
		admin: adminAuthState{
			user:          config.AdminUser,
			passwordHash:  adminHash,
			configured:    adminConfigured,
			loginAttempts: make(map[string]adminLoginAttempt),
		},
		sessionStore:     newMemorySessionStore(config.MaxSessions),
		relayClient:      client,
		telemetryService: telemetryService,
		telemetryHandler: telemetryHandler,
		telemetryWorker:  telemetryWorker,
		startedAt:        time.Now(),
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

	// Telemetry Endpoints
	if s.telemetryHandler != nil {
		s.telemetryHandler.RegisterPublicRoutes(mux)
		s.telemetryHandler.RegisterAdminRoutes(mux, adminAuth)
	}
}

// health provides an independent process liveness check that does NOT depend on Relay.
func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}

// Close gracefully stops the Admin backend service and releases held resources.
func (s *Server) Close() error {
	s.closeOnce.Do(func() {
		if s.telemetryWorker != nil {
			s.telemetryWorker.Stop()
		}
		if s.sessionStore != nil {
			_ = s.sessionStore.Close()
		}
	})
	return nil
}
