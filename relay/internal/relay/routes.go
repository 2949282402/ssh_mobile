package relay

// Canonical route patterns and path constants for Relay endpoints.
const (
	RouteHealthz     = "GET /healthz"
	RouteEnrollV2    = "POST /v2/devices/enroll"
	RouteRefreshV2   = "POST /v2/devices/refresh"
	RouteControlV2   = "GET /v2/control"
	RouteRelayDataV2 = "GET /v2/relay/{reservation_id}"

	PathHealthz     = "/healthz"
	PathEnrollV2    = "/v2/devices/enroll"
	PathRefreshV2   = "/v2/devices/refresh"
	PathControlV2   = "/v2/control"
	PathRelayDataV2 = "/v2/relay/"
)
