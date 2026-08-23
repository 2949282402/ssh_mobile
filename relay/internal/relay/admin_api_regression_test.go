package relay

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

type adminSnapshotContextKey struct{}

type adminSnapshotStorageProbe struct {
	Storage
	context context.Context
}

func (p *adminSnapshotStorageProbe) ListEnrollments(ctx context.Context) ([]*EnrolledDevice, error) {
	p.context = ctx
	return []*EnrolledDevice{}, nil
}

type adminSnapshotCacheProbe struct {
	Cache
	context context.Context
}

func (p *adminSnapshotCacheProbe) GetPresences(ctx context.Context, _ []string) (map[string]Presence, error) {
	p.context = ctx
	return map[string]Presence{}, nil
}

func TestAdminSnapshotHandlersPropagateRequestContext(t *testing.T) {
	for _, test := range []struct {
		name    string
		path    string
		handler func(*Server, http.ResponseWriter, *http.Request)
	}{
		{"overview", "/api/admin/v1/overview", (*Server).adminOverview},
		{"devices", "/api/admin/v1/devices", (*Server).adminDevices},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := NewServer(Config{})
			storage := &adminSnapshotStorageProbe{Storage: server.store}
			cache := &adminSnapshotCacheProbe{Cache: server.cache}
			server.store = storage
			server.cache = cache
			t.Cleanup(server.Close)

			request := httptest.NewRequest(http.MethodGet, test.path, nil)
			request = request.WithContext(context.WithValue(request.Context(), adminSnapshotContextKey{}, test.name))
			response := httptest.NewRecorder()
			test.handler(server, response, request)

			if response.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
			}
			if storage.context == nil || storage.context.Value(adminSnapshotContextKey{}) != test.name {
				t.Fatal("ListEnrollments did not receive the request context")
			}
			if cache.context == nil || cache.context.Value(adminSnapshotContextKey{}) != test.name {
				t.Fatal("GetPresences did not receive the request context")
			}
			if _, ok := storage.context.Deadline(); !ok {
				t.Fatal("administrator snapshot storage call has no bounded deadline")
			}
		})
	}
}
