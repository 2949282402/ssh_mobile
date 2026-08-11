// v1 Relay 服务配置、环境变量解析和随机材料生成。

package relay

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"os"
	"strconv"
	"time"
)

const (
	// maxControlFrameBytes 限制单个 JSON 控制帧的大小。
	maxControlFrameBytes = 64 * 1024
	// maxBinaryFrameBytes 限制单个不透明二进制帧的大小。
	maxBinaryFrameBytes = 1024*1024 + 25
)

// Config 保存 Relay 服务器的监听、认证和资源边界。
type Config struct {
	Address         string
	EnrollmentToken string
	CredentialKey   []byte
	CredentialTTL   time.Duration
	SessionTTL      time.Duration
	AdminSessionTTL time.Duration
	MaxConnections  int
	AdminUser       string
	AdminPassword   string
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

	adminUser := os.Getenv("RELAY_ADMIN_USER")
	if adminUser == "" {
		return Config{}, errors.New("RELAY_ADMIN_USER must be set")
	}
	adminPassword := os.Getenv("RELAY_ADMIN_PASSWORD")
	if len(adminPassword) < 12 {
		return Config{}, errors.New("RELAY_ADMIN_PASSWORD must be set and contain at least 12 characters")
	}

	return Config{
		Address:         address,
		EnrollmentToken: enrollment,
		CredentialKey:   decoded,
		CredentialTTL:   durationEnv("RELAY_CREDENTIAL_TTL", 24*time.Hour),
		SessionTTL:      durationEnv("RELAY_SESSION_TTL", 15*time.Minute),
		AdminSessionTTL: durationEnv("RELAY_ADMIN_SESSION_TTL", 24*time.Hour),
		MaxConnections:  intEnv("RELAY_MAX_CONNECTIONS", 2048),
		AdminUser:       adminUser,
		AdminPassword:   adminPassword,
	}, nil
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

// randomBytes 生成指定长度的密码学随机字节。
func randomBytes(size int) []byte {
	b := make([]byte, size)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}
