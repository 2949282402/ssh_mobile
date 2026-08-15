// v1 Relay 服务配置、环境变量解析和随机材料生成。

package relay

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	// maxControlFrameBytes 限制单个 JSON 控制帧的大小。
	maxControlFrameBytes = 384 * 1024
	// maxBinaryFrameBytes 限制单个不透明二进制帧的大小。
	maxBinaryFrameBytes = 1024*1024 + 25
	// maxChannelPayloadBytes 限制 Delivery 控制信封携带的不透明正文大小。
	maxChannelPayloadBytes = 48 * 1024
	// maxCandidatePayloadBytes 限制 Candidate Offer/Answer 的信令正文大小。
	maxCandidatePayloadBytes = 32 * 1024
	// maxRealtimeSignalPayloadBytes 限制 WebRTC SDP/ICE 信令正文大小。
	maxRealtimeSignalPayloadBytes = 256 * 1024

	defaultAddress                           = ":8080"
	defaultCredentialTTL                     = 24 * time.Hour
	defaultSessionTTL                        = 15 * time.Minute
	defaultAdminSessionTTL                   = 24 * time.Hour
	defaultMaxConnections                    = 2048
	defaultMaxEnrolledDevices                = 4096
	defaultMaxRevokedDevices                 = 4096
	defaultMaxTransferSessions               = 4096
	defaultMaxPendingFramesPerDevice         = 64
	defaultMaxPendingBytesPerDevice    int64 = 16 * 1024 * 1024
	defaultMaxFramesPerSecondPerDevice       = 256
	defaultMaxBytesPerSecondPerDevice  int64 = 64 * 1024 * 1024
	defaultMaxAdminSessions                  = 32
	defaultAdminLoginMaxAttempts             = 5
	defaultAdminLoginWindow                  = time.Minute
	defaultAdminLoginBlockDuration           = 5 * time.Minute
	defaultMaxAdminLoginEntries              = 4096
	defaultHTTPReadTimeout                   = 15 * time.Second
	defaultHTTPWriteTimeout                  = 15 * time.Second
	defaultHTTPIdleTimeout                   = 60 * time.Second
	defaultHTTPMaxHeaderBytes                = 16 * 1024
	defaultPresenceTTL                       = 60 * time.Second
	// 服务端心跳监视器默认值镜像冻结契约常量：HEARTBEAT_INTERVAL_S=20、
	// SERVER_HEARTBEAT_MISSES_BEFORE_CLOSE=2（配合 PRESENCE_TTL_S=60：60/20）。
	defaultServerHeartbeatInterval = 20 * time.Second
	defaultServerHeartbeatMisses   = 2
)

// relayEventsChannel is the Redis Pub/Sub channel carrying cross-instance
// device-lifecycle events.
const relayEventsChannel = "relay:events"

// Config 保存 Relay 服务器的监听、认证和资源边界。
type Config struct {
	Address     string
	StorageMode string
	DatabaseURL string
	RedisURL    string
	InstanceID  string
	PresenceTTL time.Duration
	// ServerHeartbeatInterval 是服务端心跳监视器的检查周期：连续
	// ServerHeartbeatMisses 个周期未收到该连接的心跳帧即关闭连接并释放 presence 租约。
	// 客户端驱动的续期（心跳路径的 RenewPresence）不受影响。
	ServerHeartbeatInterval     time.Duration
	ServerHeartbeatMisses       int
	EnrollmentToken             string
	CredentialKey               []byte
	CredentialTTL               time.Duration
	SessionTTL                  time.Duration
	AdminSessionTTL             time.Duration
	MaxConnections              int
	MaxEnrolledDevices          int
	MaxRevokedDevices           int
	MaxTransferSessions         int
	MaxPendingFramesPerDevice   int
	MaxPendingBytesPerDevice    int64
	MaxFramesPerSecondPerDevice int
	MaxBytesPerSecondPerDevice  int64
	MaxAdminSessions            int
	AdminLoginMaxAttempts       int
	AdminLoginWindow            time.Duration
	AdminLoginBlockDuration     time.Duration
	MaxAdminLoginEntries        int
	HTTPReadTimeout             time.Duration
	HTTPWriteTimeout            time.Duration
	HTTPIdleTimeout             time.Duration
	HTTPMaxHeaderBytes          int
	TrustedProxyCIDRs           []netip.Prefix
	AdminUser                   string
	AdminPassword               string
}

// ConfigFromEnvironment 从环境变量加载并校验生产 Relay 配置。
func ConfigFromEnvironment() (Config, error) {
	address := os.Getenv("RELAY_ADDR")
	if address == "" {
		address = ":8080"
	}
	enrollment := os.Getenv("RELAY_ENROLLMENT_TOKEN")
	if len(enrollment) < 16 {
		return Config{}, errors.New("RELAY_ENROLLMENT_TOKEN must be set and contain at least 16 characters")
	}

	var decoded []byte
	key := os.Getenv("RELAY_CREDENTIAL_KEY")
	if key == "" {
		return Config{}, errors.New("RELAY_CREDENTIAL_KEY must be set")
	} else {
		var err error
		decoded, err = base64.RawURLEncoding.DecodeString(key)
		if err != nil || len(decoded) < 32 {
			return Config{}, errors.New("RELAY_CREDENTIAL_KEY must be base64url encoded and at least 32 bytes")
		}
	}

	storageMode := os.Getenv("RELAY_STORAGE_MODE")
	if storageMode == "" {
		storageMode = "memory"
	}
	if storageMode != "memory" && storageMode != "mysql" {
		return Config{}, errors.New("RELAY_STORAGE_MODE must be \"memory\" or \"mysql\"")
	}
	databaseURL := os.Getenv("RELAY_DATABASE_URL")
	redisURL := os.Getenv("RELAY_REDIS_URL")
	instanceID := os.Getenv("RELAY_INSTANCE_ID")
	if storageMode == "mysql" && databaseURL == "" {
		return Config{}, errors.New("RELAY_DATABASE_URL must be set when RELAY_STORAGE_MODE=mysql")
	}
	if storageMode == "mysql" && redisURL == "" {
		// Without Redis the nonce replay cache is process-local while enrollment
		// is durable, so a restart silently reopens the replay window; require
		// Redis so mysql mode always keeps the full shared state layer.
		return Config{}, errors.New("RELAY_REDIS_URL must be set when RELAY_STORAGE_MODE=mysql")
	}

	adminUser := os.Getenv("RELAY_ADMIN_USER")
	if adminUser == "" {
		return Config{}, errors.New("RELAY_ADMIN_USER must be set")
	}
	adminPassword := os.Getenv("RELAY_ADMIN_PASSWORD")
	if len(adminPassword) < 12 {
		return Config{}, errors.New("RELAY_ADMIN_PASSWORD must be set and contain at least 12 characters")
	}

	return Config{
		Address:                     address,
		StorageMode:                 storageMode,
		DatabaseURL:                 databaseURL,
		RedisURL:                    redisURL,
		InstanceID:                  instanceID,
		PresenceTTL:                 durationEnv("RELAY_PRESENCE_TTL", defaultPresenceTTL),
		ServerHeartbeatInterval:     durationEnv("RELAY_SERVER_HEARTBEAT_INTERVAL", defaultServerHeartbeatInterval),
		ServerHeartbeatMisses:       intEnv("RELAY_SERVER_HEARTBEAT_MISSES", defaultServerHeartbeatMisses),
		EnrollmentToken:             enrollment,
		CredentialKey:               decoded,
		CredentialTTL:               durationEnv("RELAY_CREDENTIAL_TTL", defaultCredentialTTL),
		SessionTTL:                  durationEnv("RELAY_SESSION_TTL", defaultSessionTTL),
		AdminSessionTTL:             durationEnv("RELAY_ADMIN_SESSION_TTL", defaultAdminSessionTTL),
		MaxConnections:              intEnv("RELAY_MAX_CONNECTIONS", defaultMaxConnections),
		MaxEnrolledDevices:          intEnv("RELAY_MAX_ENROLLED_DEVICES", defaultMaxEnrolledDevices),
		MaxRevokedDevices:           intEnv("RELAY_MAX_REVOKED_DEVICES", defaultMaxRevokedDevices),
		MaxTransferSessions:         intEnv("RELAY_MAX_TRANSFER_SESSIONS", defaultMaxTransferSessions),
		MaxPendingFramesPerDevice:   intEnv("RELAY_MAX_PENDING_FRAMES_PER_DEVICE", defaultMaxPendingFramesPerDevice),
		MaxPendingBytesPerDevice:    int64Env("RELAY_MAX_PENDING_BYTES_PER_DEVICE", defaultMaxPendingBytesPerDevice),
		MaxFramesPerSecondPerDevice: intEnv("RELAY_MAX_FRAMES_PER_SECOND_PER_DEVICE", defaultMaxFramesPerSecondPerDevice),
		MaxBytesPerSecondPerDevice:  int64Env("RELAY_MAX_BYTES_PER_SECOND_PER_DEVICE", defaultMaxBytesPerSecondPerDevice),
		MaxAdminSessions:            intEnv("RELAY_MAX_ADMIN_SESSIONS", defaultMaxAdminSessions),
		AdminLoginMaxAttempts:       intEnv("RELAY_ADMIN_LOGIN_MAX_ATTEMPTS", defaultAdminLoginMaxAttempts),
		AdminLoginWindow:            durationEnv("RELAY_ADMIN_LOGIN_WINDOW", defaultAdminLoginWindow),
		AdminLoginBlockDuration:     durationEnv("RELAY_ADMIN_LOGIN_BLOCK", defaultAdminLoginBlockDuration),
		MaxAdminLoginEntries:        intEnv("RELAY_MAX_ADMIN_LOGIN_ENTRIES", defaultMaxAdminLoginEntries),
		HTTPReadTimeout:             durationEnv("RELAY_HTTP_READ_TIMEOUT", defaultHTTPReadTimeout),
		HTTPWriteTimeout:            durationEnv("RELAY_HTTP_WRITE_TIMEOUT", defaultHTTPWriteTimeout),
		HTTPIdleTimeout:             durationEnv("RELAY_HTTP_IDLE_TIMEOUT", defaultHTTPIdleTimeout),
		HTTPMaxHeaderBytes:          intEnv("RELAY_HTTP_MAX_HEADER_BYTES", defaultHTTPMaxHeaderBytes),
		TrustedProxyCIDRs:           cidrListEnv("RELAY_TRUSTED_PROXY_CIDRS"),
		AdminUser:                   adminUser,
		AdminPassword:               adminPassword,
	}, nil
}

// cidrListEnv parses a comma-separated list of CIDRs (or bare IP addresses)
// into prefixes. An empty or unset variable yields no trusted proxies, which is
// the secure default: the relay never honors forwarding headers in that case.
// Malformed entries are ignored, degrading toward the secure no-proxy default
// rather than silently trusting a misconfigured boundary.
func cidrListEnv(name string) []netip.Prefix {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return nil
	}
	var prefixes []netip.Prefix
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if prefix, err := netip.ParsePrefix(part); err == nil {
			prefixes = append(prefixes, prefix)
			continue
		}
		if addr, err := netip.ParseAddr(part); err == nil {
			prefixes = append(prefixes, netip.PrefixFrom(addr, addr.BitLen()))
		}
	}
	return prefixes
}

// withConfigDefaults supplies safe finite defaults for programmatic callers as
// well as environment-backed production configuration. Secrets are intentionally
// not generated here because NewServer owns their process-local initialization.
func withConfigDefaults(config Config) Config {
	if config.Address == "" {
		config.Address = defaultAddress
	}
	if config.CredentialTTL <= 0 {
		config.CredentialTTL = defaultCredentialTTL
	}
	if config.SessionTTL <= 0 {
		config.SessionTTL = defaultSessionTTL
	}
	if config.AdminSessionTTL <= 0 {
		config.AdminSessionTTL = defaultAdminSessionTTL
	}
	if config.MaxConnections <= 0 {
		config.MaxConnections = defaultMaxConnections
	}
	if config.MaxEnrolledDevices <= 0 {
		config.MaxEnrolledDevices = defaultMaxEnrolledDevices
	}
	if config.MaxRevokedDevices <= 0 {
		config.MaxRevokedDevices = defaultMaxRevokedDevices
	}
	if config.MaxTransferSessions <= 0 {
		config.MaxTransferSessions = defaultMaxTransferSessions
	}
	if config.MaxPendingFramesPerDevice <= 0 {
		config.MaxPendingFramesPerDevice = defaultMaxPendingFramesPerDevice
	}
	if config.MaxPendingBytesPerDevice <= 0 {
		config.MaxPendingBytesPerDevice = defaultMaxPendingBytesPerDevice
	}
	if config.MaxFramesPerSecondPerDevice <= 0 {
		config.MaxFramesPerSecondPerDevice = defaultMaxFramesPerSecondPerDevice
	}
	if config.MaxBytesPerSecondPerDevice <= 0 {
		config.MaxBytesPerSecondPerDevice = defaultMaxBytesPerSecondPerDevice
	}
	if config.MaxAdminSessions <= 0 {
		config.MaxAdminSessions = defaultMaxAdminSessions
	}
	if config.AdminLoginMaxAttempts <= 0 {
		config.AdminLoginMaxAttempts = defaultAdminLoginMaxAttempts
	}
	if config.AdminLoginWindow <= 0 {
		config.AdminLoginWindow = defaultAdminLoginWindow
	}
	if config.AdminLoginBlockDuration <= 0 {
		config.AdminLoginBlockDuration = defaultAdminLoginBlockDuration
	}
	if config.MaxAdminLoginEntries <= 0 {
		config.MaxAdminLoginEntries = defaultMaxAdminLoginEntries
	}
	if config.PresenceTTL <= 0 {
		config.PresenceTTL = defaultPresenceTTL
	}
	if config.ServerHeartbeatInterval <= 0 {
		config.ServerHeartbeatInterval = defaultServerHeartbeatInterval
	}
	if config.ServerHeartbeatMisses <= 0 {
		config.ServerHeartbeatMisses = defaultServerHeartbeatMisses
	}
	if config.HTTPReadTimeout <= 0 {
		config.HTTPReadTimeout = defaultHTTPReadTimeout
	}
	if config.HTTPWriteTimeout <= 0 {
		config.HTTPWriteTimeout = defaultHTTPWriteTimeout
	}
	if config.HTTPIdleTimeout <= 0 {
		config.HTTPIdleTimeout = defaultHTTPIdleTimeout
	}
	if config.HTTPMaxHeaderBytes <= 0 {
		config.HTTPMaxHeaderBytes = defaultHTTPMaxHeaderBytes
	}
	return config
}

// durationEnv 读取正的时间间隔，异常时返回指定默认值。
func durationEnv(name string, fallback time.Duration) time.Duration {
	if value, err := time.ParseDuration(os.Getenv(name)); err == nil && value > 0 {
		return value
	}
	return fallback
}

// intEnv 读取正整数资源配置，异常时返回指定默认值。
func intEnv(name string, fallback int) int {
	if value, err := strconv.Atoi(os.Getenv(name)); err == nil && value > 0 {
		return value
	}
	return fallback
}

// int64Env 读取正的 int64 资源配置，异常时返回指定默认值。
func int64Env(name string, fallback int64) int64 {
	if value, err := strconv.ParseInt(os.Getenv(name), 10, 64); err == nil && value > 0 {
		return value
	}
	return fallback
}

// randomBytes 生成指定长度的密码学随机字节。
func randomBytes(size int) []byte {
	b := make([]byte, size)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}
