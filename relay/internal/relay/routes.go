package relay

// Canonical route patterns and path constants for Relay endpoints.
const (
	RouteHealthz     = "GET /healthz"
	RouteEnrollV2    = "POST /v2/devices/enroll"
	RouteRefreshV2   = "POST /v2/devices/refresh"
	RouteControlV2   = "GET /v2/control"
	RouteRelayDataV2 = "GET /v2/relay/{reservation_id}"

	RouteInternalStatusV2       = "GET /internal/v2/status"
	RouteInternalDevicesV2      = "GET /internal/v2/devices"
	RouteInternalRevokeDeviceV2 = "POST /internal/v2/devices/{deviceId}/revoke"
	RouteInternalTokenV2        = "GET /internal/v2/access/enrollment-token"
	RouteInternalRotateTokenV2  = "POST /internal/v2/access/enrollment-token/rotate"

	PathHealthz     = "/healthz"
	PathEnrollV2    = "/v2/devices/enroll"
	PathRefreshV2   = "/v2/devices/refresh"
	PathControlV2   = "/v2/control"
	PathRelayDataV2 = "/v2/relay/"

	PathInternalStatusV2       = "/internal/v2/status"
	PathInternalDevicesV2      = "/internal/v2/devices"
	PathInternalRevokeDeviceV2 = "/internal/v2/devices/"
	PathInternalTokenV2        = "/internal/v2/access/enrollment-token"
	PathInternalRotateTokenV2  = "/internal/v2/access/enrollment-token/rotate"
)
