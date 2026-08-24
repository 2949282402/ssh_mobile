package relay

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestOpenServerBoundsStoreStartupAndDropsEndpointConfig(t *testing.T) {
	redisPassword := t.Name()
	config := Config{
		StorageMode:   "mysql",
		DatabaseURL:   "db-endpoint",
		RedisURL:      "cache-endpoint",
		RedisPassword: redisPassword,
		CredentialKey: make([]byte, 32),
	}
	memory := newMemoryStore(config)

	var mysqlDeadline, redisDeadline time.Time
	var mysqlHasDeadline, redisHasDeadline bool
	var receivedDSN, receivedRedisURL, receivedRedisPassword string
	server, err := openServerWithStores(
		config,
		func(ctx context.Context, dsn string, _ int) (Storage, error) {
			mysqlDeadline, mysqlHasDeadline = ctx.Deadline()
			receivedDSN = dsn
			return memory, nil
		},
		func(ctx context.Context, redisURL string, receivedConfig Config) (Cache, error) {
			redisDeadline, redisHasDeadline = ctx.Deadline()
			receivedRedisURL = redisURL
			receivedRedisPassword = receivedConfig.RedisPassword
			return memory, nil
		},
	)
	if err != nil {
		t.Fatalf("open server with fake stores: %v", err)
	}
	defer server.Close()

	if !mysqlHasDeadline || !redisHasDeadline {
		t.Fatalf("store openers must receive deadlines: mysql=%v redis=%v", mysqlHasDeadline, redisHasDeadline)
	}
	if !mysqlDeadline.Equal(redisDeadline) {
		t.Fatalf("store openers must share one startup deadline: mysql=%s redis=%s", mysqlDeadline, redisDeadline)
	}
	remaining := time.Until(mysqlDeadline)
	if remaining <= 0 || remaining > serverDependencyStartupTimeout {
		t.Fatalf("unexpected startup deadline remaining=%s timeout=%s", remaining, serverDependencyStartupTimeout)
	}
	if receivedDSN != config.DatabaseURL || receivedRedisURL != config.RedisURL || receivedRedisPassword != redisPassword {
		t.Fatalf("store openers did not receive startup config: dsn=%q redis_url=%q password_matches=%v",
			receivedDSN, receivedRedisURL, receivedRedisPassword == redisPassword)
	}
	if server.config.DatabaseURL != "" || server.config.RedisURL != "" || server.config.RedisPassword != "" {
		t.Fatalf("running server retained storage endpoints or password: database=%q redis=%q password_present=%v",
			server.config.DatabaseURL, server.config.RedisURL, server.config.RedisPassword != "")
	}
	// The hub intentionally has no Config field: it retains only the scalar
	// routing, capacity, and heartbeat capabilities it owns.
}

func TestNewServerDropsUnusedExternalStoreSecrets(t *testing.T) {
	sensitiveValue := t.Name()
	server := NewServer(Config{
		DatabaseURL:   sensitiveValue + "-database-endpoint",
		RedisURL:      sensitiveValue + "-cache-endpoint",
		RedisPassword: sensitiveValue + "-cache-credential",
	})
	defer server.Close()

	if server.config.DatabaseURL != "" || server.config.RedisURL != "" || server.config.RedisPassword != "" {
		t.Fatalf("memory server retained unused external-store secrets: database=%q redis=%q password_present=%v",
			server.config.DatabaseURL, server.config.RedisURL, server.config.RedisPassword != "")
	}
}

type blockingRevocationStore struct {
	Storage
	started  chan struct{}
	finished chan error
	release  chan struct{}
}

type blockingPresenceReleaseStore struct {
	presenceStore
	started chan struct{}
	release chan struct{}
}

func (store *blockingPresenceReleaseStore) ReleasePresence(context.Context, string, string) (bool, error) {
	select {
	case store.started <- struct{}{}:
	default:
	}
	<-store.release
	return true, nil
}

func TestHubCloseBoundsPresenceStoreThatIgnoresCancellation(t *testing.T) {
	base := newMemoryStore(Config{})
	store := &blockingPresenceReleaseStore{
		presenceStore: base,
		started:       make(chan struct{}, 1),
		release:       make(chan struct{}),
	}
	hub := newHub(Config{})
	hub.presence = store
	hub.mutex.Lock()
	hub.peers["blocked-device"] = &peer{
		deviceID:     "blocked-device",
		connectionID: "blocked-connection",
		done:         make(chan struct{}),
	}
	hub.mutex.Unlock()
	t.Cleanup(func() { close(store.release) })

	closed := make(chan struct{})
	startedAt := time.Now()
	go func() {
		hub.close()
		close(closed)
	}()
	select {
	case <-store.started:
	case <-time.After(time.Second):
		t.Fatal("hub close did not start presence cleanup")
	}
	select {
	case <-closed:
		elapsed := time.Since(startedAt)
		if elapsed < hubPresenceSweepTimeout || elapsed > hubPresenceSweepTimeout+time.Second {
			t.Fatalf("hub close elapsed=%s, want bounded near %s", elapsed, hubPresenceSweepTimeout)
		}
	case <-time.After(hubPresenceSweepTimeout + time.Second):
		t.Fatal("hub close remained blocked by a presence store that ignored cancellation")
	}
}

func (store *blockingRevocationStore) GetEnrollment(ctx context.Context, _ string) (*EnrolledDevice, error) {
	select {
	case store.started <- struct{}{}:
	default:
	}
	select {
	case <-ctx.Done():
		store.finished <- ctx.Err()
		return nil, ctx.Err()
	case <-store.release:
		store.finished <- nil
		return nil, nil
	}
}

func TestServerCloseCancelsInFlightRevocationReconciliation(t *testing.T) {
	server := NewServer(Config{})
	store := &blockingRevocationStore{
		Storage:  server.store,
		started:  make(chan struct{}, 1),
		finished: make(chan error, 1),
		release:  make(chan struct{}),
	}
	server.store = store
	injectPeer(server.hub, "device-a")
	t.Cleanup(func() { close(store.release) })

	server.eventsWG.Add(1)
	go func() {
		defer server.eventsWG.Done()
		server.reconcileRevocationsOnce()
	}()
	select {
	case <-store.started:
	case <-time.After(time.Second):
		t.Fatal("revocation reconciliation did not enter the blocking store")
	}

	closed := make(chan struct{})
	go func() {
		server.Close()
		close(closed)
	}()
	select {
	case <-closed:
	case <-time.After(2 * time.Second):
		t.Fatal("Server.Close remained blocked by revocation reconciliation")
	}
	select {
	case err := <-store.finished:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("reconciliation store call ended with %v, want context cancellation", err)
		}
	default:
		t.Fatal("reconciliation store call did not report its cancellation")
	}
}
