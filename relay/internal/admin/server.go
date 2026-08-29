// Admin backend HTTP server and routing.

package admin

import (
	"log/slog"
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
	logger           *slog.Logger
	startedAt        time.Time
	closeOnce        sync.Once
}

// NewServer creates a new Admin backend server with the supplied configuration.
func NewServer(config Config) *Server {
	return NewServerWithLogger(config, nil)
}

// NewServerWithClient allows injecting a custom RelayManagementClient (e.g. in tests).
func NewServerWithClient(config Config, client RelayManagementClient) *Server {
	return NewServerWithClientAndTelemetry(config, client, nil)
}

// NewServerWithClientAndTelemetry allows injecting custom RelayManagementClient and TelemetryService.
func NewServerWithClientAndTelemetry(config Config, client RelayManagementClient, telemetryService *telemetry.Service) *Server {
	return newServer(config, client, telemetryService, nil)
}

// NewServerWithLogger creates the Admin backend with an injected structured
// logger shared by startup warnings, the telemetry handler, and the retention
// worker. A nil logger falls back to slog.Default.
func NewServerWithLogger(config Config, logger *slog.Logger) *Server {
	return newServer(config, nil, nil, logger)
}

func newServer(config Config, client RelayManagementClient, telemetryService *telemetry.Service, logger *slog.Logger) *Server {
	config = withConfigDefaults(config)
	if len(config.AuthKey) == 0 {
		config.AuthKey = randomBytes(32)
	}
	if logger == nil {
		logger = slog.Default()
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
		var store telemetry.Store
		if config.TelemetryMySQLDSN != "" {
			var err error
			store, err = telemetry.NewMySQLStoreFromDSN(config.TelemetryMySQLDSN, catalog)
			if err != nil {
				// Fail-closed: never fall back to an in-memory store in production.
				// The telemetry service stays unavailable and its endpoints return 503.
				logger.Warn("telemetry MySQL unavailable; telemetry endpoints will return 503",
					"component", "admin-telemetry", "error", err)
				store = nil
			}
		} else {
			logger.Warn("TELEMETRY_MYSQL_DSN is empty; telemetry endpoints will return 503",
				"component", "admin-telemetry")
			store = nil
		}

		var redisCache telemetry.RedisCache
		if config.TelemetryRedisURL != "" {
			var err error
			redisCache, err = telemetry.NewRedisClientCacheFromURL(config.TelemetryRedisURL, "")
			if err != nil {
				logger.Warn("telemetry Redis unavailable; falling back to NoopRedisCache",
					"component", "admin-telemetry", "error", err)
				redisCache = &telemetry.NoopRedisCache{}
			}
		} else {
			redisCache = &telemetry.NoopRedisCache{}
		}

		telemetryService = telemetry.NewServiceWithSecret(store, catalog, redisCache, config.TelemetryAuthSecret)
	}

	var attestor telemetry.DeviceAttestor
	if candidate, ok := client.(telemetry.DeviceAttestor); ok {
		attestor = candidate
	}
	telemetryHandler := telemetry.NewHandlerWithConfig(telemetryService, config.TelemetryIngest, attestor).WithLogger(logger)
	telemetryWorker := telemetry.NewRetentionWorker(telemetryService, 1*time.Hour).WithLogger(logger)
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
		logger:           logger,
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
		if s.telemetryService != nil {
			_ = s.telemetryService.Close()
		}
		if s.sessionStore != nil {
			_ = s.sessionStore.Close()
		}
	})
	return nil
}
