package relay

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/ssh-mobile/relay/internal/relay/v2"
)

type boundaryResolveStore struct {
	*memoryStore
	presenceError  error
	discoveryError error
	churn          bool
	presenceCalls  int
}

func (s *boundaryResolveStore) GetPresence(ctx context.Context, deviceID string) (Presence, bool, error) {
	if s.presenceError != nil {
		return Presence{}, false, s.presenceError
	}
	if s.churn {
		s.presenceCalls++
		connectionID := "conn-a"
		if s.presenceCalls%2 == 0 {
			connectionID = "conn-b"
		}
		return Presence{ConnectionID: connectionID}, true, nil
	}
	return s.memoryStore.GetPresence(ctx, deviceID)
}

func (s *boundaryResolveStore) GetDiscovery(ctx context.Context, deviceID string) (Discovery, bool, error) {
	if s.discoveryError != nil {
		return Discovery{}, false, s.discoveryError
	}
	return s.memoryStore.GetDiscovery(ctx, deviceID)
}

func TestResolvePeerStateBoundaries(t *testing.T) {
	ctx := context.Background()
	newHubWithStore := func(store *boundaryResolveStore) *hub {
		return &hub{presence: store}
	}

	offline := &boundaryResolveStore{memoryStore: newMemoryStore(Config{})}
	if got := newHubWithStore(offline).resolvePeer(ctx, "missing"); got.status != v2.ResolveStatus_RESOLVE_STATUS_OFFLINE {
		t.Fatalf("missing presence status = %v, want offline", got.status)
	}

	notReadyStore := &boundaryResolveStore{memoryStore: newMemoryStore(Config{})}
	if _, _, err := notReadyStore.TakePresence(ctx, "target", "conn", Presence{}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if got := newHubWithStore(notReadyStore).resolvePeer(ctx, "target"); got.status != v2.ResolveStatus_RESOLVE_STATUS_NOT_READY {
		t.Fatalf("missing discovery status = %v, want not-ready", got.status)
	}

	readyStore := &boundaryResolveStore{memoryStore: newMemoryStore(Config{})}
	if _, _, err := readyStore.TakePresence(ctx, "target", "conn", Presence{}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := readyStore.TakeDiscovery(ctx, "target", "conn", Discovery{ConnectionID: "conn", Revision: 1, RuntimeEpochLow: 1}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if got := newHubWithStore(readyStore).resolvePeer(ctx, "target"); got.status != v2.ResolveStatus_RESOLVE_STATUS_READY || got.discovery.Revision != 1 {
		t.Fatalf("ready resolve = %+v, want published discovery", got)
	}

	unknownPresence := &boundaryResolveStore{memoryStore: newMemoryStore(Config{}), presenceError: errors.New("presence unavailable")}
	if got := newHubWithStore(unknownPresence).resolvePeer(ctx, "target"); got.status != v2.ResolveStatus_RESOLVE_STATUS_UNKNOWN {
		t.Fatalf("presence error status = %v, want unknown", got.status)
	}
	unknownDiscovery := &boundaryResolveStore{memoryStore: readyStore.memoryStore, discoveryError: errors.New("discovery unavailable")}
	if got := newHubWithStore(unknownDiscovery).resolvePeer(ctx, "target"); got.status != v2.ResolveStatus_RESOLVE_STATUS_UNKNOWN {
		t.Fatalf("discovery error status = %v, want unknown", got.status)
	}
	churn := &boundaryResolveStore{memoryStore: newMemoryStore(Config{}), churn: true}
	if got := newHubWithStore(churn).resolvePeer(ctx, "target"); got.status != v2.ResolveStatus_RESOLVE_STATUS_UNKNOWN {
		t.Fatalf("owner churn status = %v, want unknown", got.status)
	}
}
