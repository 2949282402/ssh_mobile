// Telemetry backend configuration.

package telemetry

import (
	"fmt"
	"math"
	"os"
	"strconv"
	"time"
)

const (
	// Ingest backpressure defaults are deliberately small enough for the
	// supported 2C4G deployment while leaving room for the normal client
	// policy's 100-record upload.
	DefaultIngestMaxBatchSize          = 100
	DefaultIngestConcurrentWriters     = 4
	DefaultIngestRateLimitCapacity     = 10
	DefaultIngestRateLimitRefillPerSec = 1.0
	DefaultIngestRateLimitMaxDevices   = 4096
	DefaultIngestRateLimitDeviceTTL    = 10 * time.Minute
	DefaultIngestRetryAfterSeconds     = 1

	minIngestConcurrentWriters = 4
	maxIngestConcurrentWriters = 8
	maxIngestBatchSize         = 100
	maxIngestBodyBytes         = 1 << 20
	maxIngestRateLimitCapacity = 1000
	maxIngestRateLimitRefill   = 1000.0
	maxIngestRateLimitDevices  = 65536
	maxIngestDeviceTTL         = 24 * time.Hour
	maxIngestRetryAfterSeconds = 60
)

// IngestConfig controls the public telemetry upload admission gates. Values
// are normalized by NewHandlerWithConfig so callers cannot accidentally
// remove the bounded resource limits that protect a small deployment.
//
// Clock is injectable for deterministic rate-limit tests. Production callers
// should leave it nil so the handler uses UTC wall-clock time.
type IngestConfig struct {
	MaxBodyBytes             int64
	MaxBatchSize             int
	MaxConcurrentWriters     int
	RateLimitCapacity        int
	RateLimitRefillPerSecond float64
	// RateLimitRefillPerSec is retained as a source-compatible shorthand for
	// callers that used the initial configuration spelling.
	RateLimitRefillPerSec float64
	RateLimitMaxDevices   int
	RateLimitDeviceTTL    time.Duration
	RetryAfterSeconds     int
	Clock                 func() time.Time
}

// DefaultIngestConfig returns the conservative public-ingest limits.
func DefaultIngestConfig() IngestConfig {
	return IngestConfig{
		MaxBodyBytes:             MaxRequestBodyBytes,
		MaxBatchSize:             DefaultIngestMaxBatchSize,
		MaxConcurrentWriters:     DefaultIngestConcurrentWriters,
		RateLimitCapacity:        DefaultIngestRateLimitCapacity,
		RateLimitRefillPerSecond: DefaultIngestRateLimitRefillPerSec,
		RateLimitRefillPerSec:    DefaultIngestRateLimitRefillPerSec,
		RateLimitMaxDevices:      DefaultIngestRateLimitMaxDevices,
		RateLimitDeviceTTL:       DefaultIngestRateLimitDeviceTTL,
		RetryAfterSeconds:        DefaultIngestRetryAfterSeconds,
		Clock:                    func() time.Time { return time.Now().UTC() },
	}
}

func normalizeIngestConfig(config IngestConfig) IngestConfig {
	defaults := DefaultIngestConfig()
	if config.MaxBodyBytes <= 0 {
		config.MaxBodyBytes = defaults.MaxBodyBytes
	} else if config.MaxBodyBytes > maxIngestBodyBytes {
		config.MaxBodyBytes = maxIngestBodyBytes
	}
	if config.MaxBatchSize <= 0 {
		config.MaxBatchSize = defaults.MaxBatchSize
	} else if config.MaxBatchSize > maxIngestBatchSize {
		config.MaxBatchSize = maxIngestBatchSize
	}
	if config.MaxConcurrentWriters < minIngestConcurrentWriters {
		config.MaxConcurrentWriters = minIngestConcurrentWriters
	} else if config.MaxConcurrentWriters > maxIngestConcurrentWriters {
		config.MaxConcurrentWriters = maxIngestConcurrentWriters
	}
	if config.RateLimitCapacity <= 0 {
		config.RateLimitCapacity = defaults.RateLimitCapacity
	} else if config.RateLimitCapacity > maxIngestRateLimitCapacity {
		config.RateLimitCapacity = maxIngestRateLimitCapacity
	}
	if config.RateLimitRefillPerSecond <= 0 || math.IsNaN(config.RateLimitRefillPerSecond) {
		config.RateLimitRefillPerSecond = config.RateLimitRefillPerSec
	}
	if config.RateLimitRefillPerSecond <= 0 {
		config.RateLimitRefillPerSecond = defaults.RateLimitRefillPerSecond
	}
	if config.RateLimitRefillPerSecond > maxIngestRateLimitRefill {
		config.RateLimitRefillPerSecond = maxIngestRateLimitRefill
	}
	config.RateLimitRefillPerSec = config.RateLimitRefillPerSecond
	if config.RateLimitMaxDevices <= 0 {
		config.RateLimitMaxDevices = defaults.RateLimitMaxDevices
	} else if config.RateLimitMaxDevices > maxIngestRateLimitDevices {
		config.RateLimitMaxDevices = maxIngestRateLimitDevices
	}
	if config.RateLimitDeviceTTL <= 0 {
		config.RateLimitDeviceTTL = defaults.RateLimitDeviceTTL
	} else if config.RateLimitDeviceTTL > maxIngestDeviceTTL {
		config.RateLimitDeviceTTL = maxIngestDeviceTTL
	}
	if config.RetryAfterSeconds <= 0 {
		config.RetryAfterSeconds = defaults.RetryAfterSeconds
	} else if config.RetryAfterSeconds > maxIngestRetryAfterSeconds {
		config.RetryAfterSeconds = maxIngestRetryAfterSeconds
	}
	if config.Clock == nil {
		config.Clock = defaults.Clock
	}
	return config
}

// IngestConfigFromEnvironment loads optional public-ingest limits. Empty
// variables retain the safe defaults; values outside the hard bounds are
// clamped by normalizeIngestConfig so deployment configuration cannot disable
// the resource protections.
func IngestConfigFromEnvironment() (IngestConfig, error) {
	config := DefaultIngestConfig()
	var err error
	readInt64 := func(name string, current int64) int64 {
		raw := os.Getenv(name)
		if raw == "" || err != nil {
			return current
		}
		value, parseErr := strconv.ParseInt(raw, 10, 64)
		if parseErr != nil || value <= 0 {
			if parseErr == nil {
				err = fmt.Errorf("%s must be a positive integer", name)
			} else {
				err = fmt.Errorf("%s must be a positive integer: %w", name, parseErr)
			}
			return current
		}
		return value
	}
	readInt := func(name string, current int) int {
		value := readInt64(name, int64(current))
		return int(value)
	}
	readFloat := func(name string, current float64) float64 {
		raw := os.Getenv(name)
		if raw == "" || err != nil {
			return current
		}
		value, parseErr := strconv.ParseFloat(raw, 64)
		if parseErr != nil || value <= 0 || math.IsNaN(value) || math.IsInf(value, 0) {
			if parseErr == nil {
				err = fmt.Errorf("%s must be a positive number", name)
			} else {
				err = fmt.Errorf("%s must be a positive number: %w", name, parseErr)
			}
			return current
		}
		return value
	}
	readDuration := func(name string, current time.Duration) time.Duration {
		raw := os.Getenv(name)
		if raw == "" || err != nil {
			return current
		}
		value, parseErr := time.ParseDuration(raw)
		if parseErr != nil || value <= 0 {
			if parseErr == nil {
				err = fmt.Errorf("%s must be a positive duration", name)
			} else {
				err = fmt.Errorf("%s must be a positive duration: %w", name, parseErr)
			}
			return current
		}
		return value
	}

	config.MaxBodyBytes = readInt64("TELEMETRY_MAX_BODY_BYTES", config.MaxBodyBytes)
	config.MaxBatchSize = readInt("TELEMETRY_MAX_BATCH_SIZE", config.MaxBatchSize)
	config.MaxConcurrentWriters = readInt("TELEMETRY_MAX_CONCURRENT_WRITERS", config.MaxConcurrentWriters)
	config.RateLimitCapacity = readInt("TELEMETRY_RATE_LIMIT_CAPACITY", config.RateLimitCapacity)
	config.RateLimitRefillPerSecond = readFloat("TELEMETRY_RATE_LIMIT_REFILL_PER_SECOND", config.RateLimitRefillPerSecond)
	config.RateLimitMaxDevices = readInt("TELEMETRY_RATE_LIMIT_MAX_DEVICES", config.RateLimitMaxDevices)
	config.RateLimitDeviceTTL = readDuration("TELEMETRY_RATE_LIMIT_DEVICE_TTL", config.RateLimitDeviceTTL)
	config.RetryAfterSeconds = readInt("TELEMETRY_RETRY_AFTER_SECONDS", config.RetryAfterSeconds)
	if err != nil {
		return IngestConfig{}, err
	}
	return normalizeIngestConfig(config), nil
}

type Config struct {
	MySQLDSN              string
	RedisURL              string
	EnrollRoute           string
	RotateRoute           string
	AuthRoute             string
	IngestRoute           string
	PolicyRoute           string
	AdminOverviewRoute    string
	AdminEventsRoute      string
	AdminDiagnosticsRoute string
	AdminSettingsRoute    string
	RetentionInterval     time.Duration
	MaxBodyBytes          int64
	Ingest                IngestConfig
}

func DefaultConfig() Config {
	ingestConfig, err := IngestConfigFromEnvironment()
	if err != nil {
		ingestConfig = DefaultIngestConfig()
	}
	return Config{
		MySQLDSN:              os.Getenv("TELEMETRY_MYSQL_DSN"),
		RedisURL:              os.Getenv("TELEMETRY_REDIS_URL"),
		EnrollRoute:           RoutePublicEnroll,
		RotateRoute:           RoutePublicRotate,
		AuthRoute:             RoutePublicAuth,
		IngestRoute:           RoutePublicIngest,
		PolicyRoute:           RoutePublicPolicy,
		AdminOverviewRoute:    RouteAdminOverview,
		AdminEventsRoute:      RouteAdminEvents,
		AdminDiagnosticsRoute: RouteAdminDiagnostics,
		AdminSettingsRoute:    RouteAdminSettings,
		RetentionInterval:     1 * time.Hour,
		MaxBodyBytes:          ingestConfig.MaxBodyBytes,
		Ingest:                ingestConfig,
	}
}
