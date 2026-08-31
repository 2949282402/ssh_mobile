// Canonical route patterns and path constants for Telemetry endpoints.

package telemetry

const (
	RoutePublicEnroll = "/api/v1/telemetry/enroll"
	RoutePublicRotate = "/api/v1/telemetry/enroll/rotate"
	RoutePublicAuth   = "/api/v1/telemetry/auth"
	RoutePublicIngest = "/api/v1/telemetry/ingest"
	RoutePublicPolicy = "/api/v1/telemetry/policy"

	RouteAdminOverview    = "/api/admin/v1/telemetry/overview"
	RouteAdminEvents      = "/api/admin/v1/telemetry/events"
	RouteAdminDiagnostics = "/api/admin/v1/telemetry/diagnostics"
	RouteAdminSettings    = "/api/admin/v1/telemetry/settings"

	PathPublicAuth   = "/api/v1/telemetry/auth"
	PathPublicEnroll = "/api/v1/telemetry/enroll"
	PathPublicRotate = "/api/v1/telemetry/enroll/rotate"
	PathPublicIngest = "/api/v1/telemetry/ingest"
	PathPublicPolicy = "/api/v1/telemetry/policy"

	PathAdminOverview    = "/api/admin/v1/telemetry/overview"
	PathAdminEvents      = "/api/admin/v1/telemetry/events"
	PathAdminDiagnostics = "/api/admin/v1/telemetry/diagnostics"
	PathAdminSettings    = "/api/admin/v1/telemetry/settings"
)
