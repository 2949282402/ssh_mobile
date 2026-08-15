// Relay server composition and route registration.
//
// The device protocol remains under /v1. Administrative HTTP handlers live in
// the admin_* files, while device and hub behavior is kept in their own
// protocol-focused files.

package relay

import (
	"context"
	"encoding/hex"
	"fmt"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type Server struct {
	config   Config
	hub      *hub
	upgrader websocket.Upgrader
	store    Storage
	cache    Cache
	admin    adminAuthState
	// relayData 是 /v2/relay/{reservation_id} 数据面端点的链接注册表（设计 §25）。
	// 它与 hub 的 peer 表完全独立：数据面连接没有 presence 租约，只按 reservation 配对。
	relayData    relayDataRegistry
	startedAt    time.Time
	eventsCtx    context.Context
	eventsCancel context.CancelFunc
	eventsWG     sync.WaitGroup
	logger       *slog.Logger

	// deviceLocks 是 per-device 分片锁（与 hub 的 admission 条纹同构）：同设备复合
	// 操作（enroll/revoke/authenticate）在同一条纹上串行以保留原子性，不同设备
	// 并行访问存储——MySQL 模式不再被全局 devicesMutex 退化成单并发。tokenMutex
	// 单独保护无 deviceID 可锁的 EnrollmentToken 标量。
	deviceLocks [deviceLockStripeCount]sync.Mutex
	tokenMutex  sync.Mutex
}

// deviceLockStripeCount 是 per-device 分片锁的条纹数。同一设备的操作经 fnv-1a
// 哈希落到同一条纹上串行（保留复合原子性），不同设备极少碰撞且只短暂等待。
const deviceLockStripeCount = 128

// lockDevice 为 deviceID 串行化复合设备操作并返回解锁函数。单个存储调用不需要
// 它——memoryStore 与 mysqlStore 均已内部并发安全；它只保护跨多个 store/cache
// 调用的原子单元（revoke/enroll/authenticate）。
func (s *Server) lockDevice(deviceID string) func() {
	stripe := deviceLockStripe(deviceID) % deviceLockStripeCount
	s.deviceLocks[stripe].Lock()
	return s.deviceLocks[stripe].Unlock
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
	if config.InstanceID == "" {
		config.InstanceID = "relay-" + hex.EncodeToString(randomBytes(6))
	}

	adminPasswordHash := passwordDigest(config.CredentialKey, config.AdminPassword)
	adminConfigured := config.AdminUser != "" && len(config.AdminPassword) >= 12
	config.AdminPassword = ""

	// Phase 0 ships the in-memory store only; RELAY_STORAGE_MODE selects it and
	// Phase 1/2 add the MySQL/Redis implementations behind the same contract.
	memory := newMemoryStore(config)
	eventsCtx, eventsCancel := context.WithCancel(context.Background())

	server := &Server{
		config:   config,
		hub:      newHub(config),
		upgrader: websocket.Upgrader{},
		store:    memory,
		cache:    memory,
		admin: adminAuthState{
			user:          config.AdminUser,
			passwordHash:  adminPasswordHash,
			configured:    adminConfigured,
			loginAttempts: make(map[string]adminLoginAttempt),
		},
		relayData:    *newRelayDataRegistry(),
		startedAt:    time.Now(),
		eventsCtx:    eventsCtx,
		eventsCancel: eventsCancel,
		logger:       slog.Default(),
	}
	server.hub.presence = server.cache
	return server
}

// Close 停止 Relay hub，释放活跃设备连接与底层存储。
func (s *Server) Close() {
	s.eventsCancel()
	s.hub.close()
	s.eventsWG.Wait()
	_ = s.cache.Close()
	_ = s.store.Close()
}

// OpenServer 根据 config.StorageMode 构建 Relay 服务：memory 模式与 NewServer
// 等价；mysql 模式额外打开数据库（并在配置 RELAY_REDIS_URL 时激活 Redis 缓存层）。
func OpenServer(config Config) (*Server, error) {
	config = withConfigDefaults(config)
	switch config.StorageMode {
	case "", "memory":
		return NewServer(config), nil
	case "mysql":
		if config.DatabaseURL == "" {
			return nil, fmt.Errorf("RELAY_DATABASE_URL must be set when RELAY_STORAGE_MODE=mysql")
		}
		if config.RedisURL == "" {
			// Required: durable enrollment with a process-local nonce cache would
			// reopen the replay window on restart (see config validation).
			return nil, fmt.Errorf("RELAY_REDIS_URL must be set when RELAY_STORAGE_MODE=mysql")
		}
		store, err := openMySQLStore(context.Background(), config.DatabaseURL, config.MaxEnrolledDevices)
		if err != nil {
			return nil, fmt.Errorf("open mysql store: %w", err)
		}
		redis, err := openRedisStore(context.Background(), config.RedisURL)
		if err != nil {
			// The MySQL store is already open; without this close its connection
			// pool (and the prune goroutine started by openMySQLStore) would be
			// leaked. mysqlStore.Close is idempotent, so this is safe even if the
			// store was never used.
			_ = store.Close()
			return nil, fmt.Errorf("open redis store: %w", err)
		}
		server := NewServer(config)
		server.store = store
		server.cache = redis
		server.hub.presence = redis
		server.startEventSubscribers()
		// Redis 激活时额外启动僵尸 peer 清扫，与事件订阅共用生命周期。
		server.startPresenceSweeper()
		return server, nil
	default:
		return nil, fmt.Errorf("unsupported storage mode %q", config.StorageMode)
	}
}

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
	mux.HandleFunc("GET /v1/peers", s.listPeers)

	// Transport Network V2（设计 §24）：控制面与数据面物理拆开。
	// GET /v2/control —— 长期存活的控制面，只走 RelayFrame（protobuf）。
	mux.HandleFunc("GET /v2/control", s.connectControlV2)
	// GET /v2/relay/{reservation_id} —— reservation 作用域的不透明数据面，只走
	// RelayDataFrame；reservation 由 /v2/control 的 RelayReserveRequest 创建（§25）。
	mux.HandleFunc("GET /v2/relay/{reservation_id}", s.connectRelayData)
}

// health 提供无需认证的存活检查端点。
func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}
