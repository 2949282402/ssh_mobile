// Telemetry backend configuration.

package telemetry

import (
	"os"
	"time"
)

type Config struct {
	MySQLDSN              string
	RedisURL              string
	AuthRoute             string
	IngestRoute           string
	PolicyRoute           string
	AdminOverviewRoute    string
	AdminEventsRoute      string
	AdminDiagnosticsRoute string
	AdminSettingsRoute    string
	RetentionInterval     time.Duration
	MaxBodyBytes          int64
}

func DefaultConfig() Config {
	return Config{
		MySQLDSN:              os.Getenv("TELEMETRY_MYSQL_DSN"),
		RedisURL:              os.Getenv("TELEMETRY_REDIS_URL"),
		AuthRoute:             RoutePublicAuth,
		IngestRoute:           RoutePublicIngest,
		PolicyRoute:           RoutePublicPolicy,
		AdminOverviewRoute:    RouteAdminOverview,
		AdminEventsRoute:      RouteAdminEvents,
		AdminDiagnosticsRoute: RouteAdminDiagnostics,
		AdminSettingsRoute:    RouteAdminSettings,
		RetentionInterval:     1 * time.Hour,
		MaxBodyBytes:          MaxRequestBodyBytes,
	}
}
