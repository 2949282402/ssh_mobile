package telemetry

import (
	"net/http"
	"strconv"
	"time"
)

// parseQueryFilter translates the shared Admin filter contract into the store
// representation. Relative ranges are bounded by the server's receivedAt clock
// so MemoryStore and MySQLStore apply the same window.
func parseQueryFilter(r *http.Request) QueryFilter {
	q := r.URL.Query()
	f := QueryFilter{
		TimeRange:  q.Get("timeRange"),
		DeviceID:   q.Get("deviceId"),
		TraceID:    q.Get("traceId"),
		EventName:  q.Get("eventName"),
		Feature:    q.Get("feature"),
		Severity:   Severity(q.Get("severity")),
		ErrorCode:  q.Get("errorCode"),
		AppVersion: q.Get("appVersion"),
		Platform:   q.Get("platform"),
	}

	if st := q.Get("startTime"); st != "" {
		if t, err := time.Parse(time.RFC3339, st); err == nil {
			f.StartTime = t
		}
	}
	if et := q.Get("endTime"); et != "" {
		if t, err := time.Parse(time.RFC3339, et); err == nil {
			f.EndTime = t
		}
	}

	f = normalizeOverviewFilter(f, time.Now().UTC())

	if p, err := strconv.Atoi(q.Get("page")); err == nil && p > 0 {
		f.Page = p
	} else {
		f.Page = 1
	}

	if ps, err := strconv.Atoi(q.Get("pageSize")); err == nil && ps > 0 && ps <= 200 {
		f.PageSize = ps
	} else {
		f.PageSize = 50
	}

	return f
}
