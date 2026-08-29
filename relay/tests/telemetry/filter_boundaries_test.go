package telemetry_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestAdminFilterAcceptsExplicitBoundsAndPagination(t *testing.T) {
	service, _ := newTestService(testAuthSecret)
	mux := handlerMux(NewHandler(service))
	req := httptest.NewRequest(
		http.MethodGet,
		PathAdminEvents+"?startTime=2026-08-28T00:00:00Z&endTime=2026-08-29T00:00:00Z&page=2&pageSize=7",
		nil,
	)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("explicit filter status = %d: %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, `"page":2`) || !strings.Contains(body, `"pageSize":7`) {
		t.Fatalf("explicit filter pagination = %s, want page 2/pageSize 7", body)
	}
}
