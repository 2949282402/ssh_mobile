package admin

// Canonical route patterns and path constants for Admin backend endpoints.
const (
	RouteHealthz     = "GET /healthz"
	RouteAuthLogin   = "POST /api/admin/v1/auth/login"
	RouteAuthLogout  = "POST /api/admin/v1/auth/logout"
	RouteAuthSession = "GET /api/admin/v1/auth/session"

	RouteOverview        = "GET /api/admin/v1/overview"
	RouteDevices         = "GET /api/admin/v1/devices"
	RouteRevokeDevice    = "POST /api/admin/v1/devices/{deviceId}/revoke"
	RouteEnrollmentToken = "GET /api/admin/v1/access/enrollment-token"
	RouteRotateToken     = "POST /api/admin/v1/access/enrollment-token/rotate"

	PathHealthz     = "/healthz"
	PathAuthLogin   = "/api/admin/v1/auth/login"
	PathAuthLogout  = "/api/admin/v1/auth/logout"
	PathAuthSession = "/api/admin/v1/auth/session"

	PathOverview        = "/api/admin/v1/overview"
	PathDevices         = "/api/admin/v1/devices"
	PathRevokeDevice    = "/api/admin/v1/devices/"
	PathEnrollmentToken = "/api/admin/v1/access/enrollment-token"
	PathRotateToken     = "/api/admin/v1/access/enrollment-token/rotate"

	// Relay internal management endpoints consumed by Admin backend.
	RelayInternalPathStatus          = "/internal/v2/status"
	RelayInternalPathDevices         = "/internal/v2/devices"
	RelayInternalPathToken           = "/internal/v2/access/enrollment-token"
	RelayInternalPathRotateToken     = "/internal/v2/access/enrollment-token/rotate"
	RelayInternalPathRevokePrefix    = "/internal/v2/devices/"
	RelayInternalPathTelemetryAttest = "/internal/v2/telemetry/attest"
)
