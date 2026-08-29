package telemetry_test

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

type serviceBoundaryStore struct {
	Store
	credential       string
	credentialErr    error
	settings         *TelemetrySettings
	settingsErr      error
	events           []TelemetryEnvelope
	eventsTotal      int
	eventsErr        error
	diagnostics      []TelemetryEnvelope
	diagnosticsTotal int
	diagnosticsErr   error
	saveErr          error
	purgeCount       int
	purgeErr         error
	purgeCutoff      time.Time
	purgeMaxRows     int
	purgeBatch       int
	closeErr         error
}

func (s *serviceBoundaryStore) GetDeviceCredential(context.Context, string) (string, error) {
	if s.credentialErr != nil {
		return "", s.credentialErr
	}
	return s.credential, nil
}

func (s *serviceBoundaryStore) QueryEvents(context.Context, QueryFilter) ([]TelemetryEnvelope, int, error) {
	return s.events, s.eventsTotal, s.eventsErr
}

func (s *serviceBoundaryStore) QueryDiagnostics(context.Context, QueryFilter) ([]TelemetryEnvelope, int, error) {
	return s.diagnostics, s.diagnosticsTotal, s.diagnosticsErr
}

func (s *serviceBoundaryStore) GetSettings(context.Context) (*TelemetrySettings, error) {
	if s.settingsErr != nil {
		return nil, s.settingsErr
	}
	if s.settings == nil {
		settings := DefaultSettings()
		return &settings, nil
	}
	settings := *s.settings
	return &settings, nil
}

func (s *serviceBoundaryStore) SaveSettings(context.Context, TelemetrySettings) error {
	return s.saveErr
}

func (s *serviceBoundaryStore) PurgeRetention(_ context.Context, cutoff time.Time, maxRows, batchSize int) (int, error) {
	s.purgeCutoff = cutoff
	s.purgeMaxRows = maxRows
	s.purgeBatch = batchSize
	return s.purgeCount, s.purgeErr
}

func (s *serviceBoundaryStore) Close() error { return s.closeErr }

type serviceBoundaryCreatorStore struct {
	*serviceBoundaryStore
	createErr error
}

func (s *serviceBoundaryCreatorStore) CreateDeviceCredential(context.Context, string, string) error {
	return s.createErr
}

type serviceBoundaryCache struct {
	mu        sync.Mutex
	recent    []TelemetryEnvelope
	recentErr error
	closeErr  error
	lastLimit int
}

func (c *serviceBoundaryCache) PushDiagnostic(context.Context, TelemetryEnvelope, int) error {
	return nil
}

func (c *serviceBoundaryCache) GetRecentDiagnostics(_ context.Context, limit int) ([]TelemetryEnvelope, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.lastLimit = limit
	return c.recent, c.recentErr
}

func (c *serviceBoundaryCache) Close() error { return c.closeErr }

func TestServiceAuthAndTokenBoundaries(t *testing.T) {
	base := NewMemoryStore(DefaultCatalog())
	service := NewServiceWithSecret(base, nil, nil, "  "+testAuthSecret+"  ")
	if !service.Available() {
		t.Fatal("service with trimmed valid secret should be available")
	}
	_, deviceHash := registerDevice(t, base, "service-boundary-device")
	exp := futureEpoch()
	validProof := deviceProof("service-boundary-device", deviceHash, exp)
	for _, tc := range []struct {
		name   string
		device string
		hash   string
		proof  string
		exp    int64
	}{
		{name: "invalid device", device: "bad:device", hash: deviceHash, proof: validProof, exp: exp},
		{name: "missing hash", device: "service-boundary-device", proof: validProof, exp: exp},
		{name: "missing proof", device: "service-boundary-device", hash: deviceHash, exp: exp},
		{name: "non-positive epoch", device: "service-boundary-device", hash: deviceHash, proof: validProof},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if VerifyDeviceProof(tc.device, tc.hash, tc.proof, tc.exp) {
				t.Fatal("invalid proof input was accepted")
			}
		})
	}

	if _, _, err := service.AuthenticateDevice(context.Background(), "bad:device", validProof, exp); !errors.Is(err, ErrAuthFailed) {
		t.Fatalf("invalid device authentication error = %v, want ErrAuthFailed", err)
	}
	blankCredential := &serviceBoundaryStore{Store: base, credential: "   "}
	blankService := NewServiceWithSecret(blankCredential, DefaultCatalog(), nil, testAuthSecret)
	if _, _, err := blankService.AuthenticateDevice(context.Background(), "service-boundary-device", validProof, exp); !errors.Is(err, ErrDeviceNotRegistered) {
		t.Fatalf("blank credential authentication error = %v, want ErrDeviceNotRegistered", err)
	}
	lookupFailure := &serviceBoundaryStore{Store: base, credentialErr: errors.New("credential lookup failed")}
	lookupService := NewServiceWithSecret(lookupFailure, DefaultCatalog(), nil, testAuthSecret)
	if _, _, err := lookupService.AuthenticateDevice(context.Background(), "service-boundary-device", validProof, exp); !errors.Is(err, ErrServiceUnavailable) {
		t.Fatalf("credential lookup error = %v, want ErrServiceUnavailable", err)
	}

	if token, expiry := service.GenerateDeviceToken("bad:device", time.Hour); token != "" || expiry != 0 {
		t.Fatalf("invalid device token = %q/%d, want empty/zero", token, expiry)
	}
	if token, expiry := service.GenerateDeviceToken("service-boundary-device", 0); token == "" || expiry <= 0 {
		t.Fatalf("non-positive token duration = %q/%d, want default token", token, expiry)
	}
	validToken, _ := service.GenerateDeviceToken("service-boundary-device", time.Hour)
	for _, tc := range []struct {
		name   string
		device string
		token  string
	}{
		{name: "empty token", device: "service-boundary-device"},
		{name: "invalid device", device: "bad:device", token: validToken},
		{name: "non-numeric expiry", device: "service-boundary-device", token: "not-a-number.signature"},
		{name: "zero expiry", device: "service-boundary-device", token: "0.signature"},
		{name: "wrong signature", device: "service-boundary-device", token: strings.TrimSuffix(validToken, "a") + "b"},
	} {
		t.Run("verify "+tc.name, func(t *testing.T) {
			if service.VerifyDeviceToken(tc.device, tc.token) {
				t.Fatal("invalid token was accepted")
			}
		})
	}

	if err := base.RegisterDeviceCredential(context.Background(), "ignored", "hash"); err != nil {
		t.Fatalf("RegisterDeviceCredential with a wired store: %v", err)
	}
	noStore := NewService(nil, DefaultCatalog(), nil)
	if err := noStore.UpdateSettings(context.Background(), TelemetrySettings{}); !errors.Is(err, ErrServiceUnavailable) {
		t.Fatalf("UpdateSettings without a store = %v, want unavailable", err)
	}
}

func enrollmentBoundaryRequest() TelemetryEnrollmentRequest {
	return TelemetryEnrollmentRequest{
		DeviceID:        "service-enrollment-device",
		RelayCredential: "relay-credential",
		PublicKey:       "public-key",
		Timestamp:       time.Now().Unix(),
		Nonce:           "nonce",
		Signature:       "signature",
	}
}

func TestServiceEnrollmentBoundaries(t *testing.T) {
	base := NewMemoryStore(DefaultCatalog())
	request := enrollmentBoundaryRequest()
	validAttestor := &testDeviceAttestor{result: DeviceAttestation{DeviceID: request.DeviceID}}

	noCreator := &serviceBoundaryStore{Store: base}
	service := NewServiceWithSecret(noCreator, DefaultCatalog(), nil, testAuthSecret)
	if _, err := service.EnrollDevice(context.Background(), request, validAttestor); !errors.Is(err, ErrServiceUnavailable) {
		t.Fatalf("enrollment without creator capability = %v, want unavailable", err)
	}

	unavailableAttestor := &testDeviceAttestor{err: ErrDeviceAttestorUnavailable}
	creator := &serviceBoundaryCreatorStore{
		serviceBoundaryStore: &serviceBoundaryStore{Store: base},
		createErr:            nil,
	}
	service = NewServiceWithSecret(creator, DefaultCatalog(), nil, testAuthSecret)
	if _, err := service.EnrollDevice(context.Background(), request, unavailableAttestor); !errors.Is(err, ErrServiceUnavailable) {
		t.Fatalf("unavailable attestor error = %v, want unavailable", err)
	}
	wrongAttestor := &testDeviceAttestor{result: DeviceAttestation{DeviceID: "another-device"}}
	if _, err := service.EnrollDevice(context.Background(), request, wrongAttestor); !errors.Is(err, ErrEnrollmentProofFailed) {
		t.Fatalf("mismatched attestation error = %v, want proof failure", err)
	}

	duplicate := &serviceBoundaryCreatorStore{
		serviceBoundaryStore: &serviceBoundaryStore{Store: NewMemoryStore(DefaultCatalog())},
		createErr:            ErrDeviceCredentialAlreadyExists,
	}
	service = NewServiceWithSecret(duplicate, DefaultCatalog(), nil, testAuthSecret)
	if _, err := service.EnrollDevice(context.Background(), request, validAttestor); !errors.Is(err, ErrEnrollmentAlreadyExists) {
		t.Fatalf("duplicate enrollment error = %v, want already exists", err)
	}

	genericCreate := &serviceBoundaryCreatorStore{
		serviceBoundaryStore: &serviceBoundaryStore{Store: NewMemoryStore(DefaultCatalog())},
		createErr:            errors.New("credential database failed"),
	}
	service = NewServiceWithSecret(genericCreate, DefaultCatalog(), nil, testAuthSecret)
	if _, err := service.EnrollDevice(context.Background(), request, validAttestor); !errors.Is(err, ErrServiceUnavailable) {
		t.Fatalf("generic credential persistence error = %v, want unavailable", err)
	}

	if _, err := service.RotateDevice(context.Background(), request, nil); !errors.Is(err, ErrServiceUnavailable) {
		t.Fatalf("rotate with nil attestor = %v, want unavailable", err)
	}
	var nilService *Service
	if _, err := nilService.RotateDevice(context.Background(), request, validAttestor); !errors.Is(err, ErrServiceUnavailable) {
		t.Fatalf("rotate on nil service = %v, want unavailable", err)
	}
	invalid := request
	invalid.DeviceID = "bad:device"
	service = NewServiceWithSecret(creator, DefaultCatalog(), nil, testAuthSecret)
	if _, err := service.RotateDevice(context.Background(), invalid, validAttestor); !errors.Is(err, ErrEnrollmentInvalidRequest) {
		t.Fatalf("invalid rotation request = %v, want invalid request", err)
	}

	missing := &serviceBoundaryStore{Store: NewMemoryStore(DefaultCatalog()), credentialErr: ErrDeviceCredentialNotFound}
	service = NewServiceWithSecret(missing, DefaultCatalog(), nil, testAuthSecret)
	if _, err := service.RotateDevice(context.Background(), request, validAttestor); !errors.Is(err, ErrEnrollmentCredentialMissing) {
		t.Fatalf("missing rotation credential = %v, want not enrolled", err)
	}
	lookupFailure := &serviceBoundaryStore{Store: NewMemoryStore(DefaultCatalog()), credentialErr: errors.New("credential lookup failed")}
	service = NewServiceWithSecret(lookupFailure, DefaultCatalog(), nil, testAuthSecret)
	if _, err := service.RotateDevice(context.Background(), request, validAttestor); !errors.Is(err, ErrServiceUnavailable) {
		t.Fatalf("rotation credential lookup failure = %v, want unavailable", err)
	}
	validAttestor.seen = nil
	baseRotation := NewMemoryStore(DefaultCatalog())
	if err := baseRotation.RegisterDeviceCredential(context.Background(), request.DeviceID, "existing-hash"); err != nil {
		t.Fatal(err)
	}
	rotation := &serviceBoundaryStore{Store: baseRotation, credential: "existing-hash"}
	service = NewServiceWithSecret(rotation, DefaultCatalog(), nil, testAuthSecret)
	if _, err := service.RotateDevice(context.Background(), request, validAttestor); err != nil {
		t.Fatalf("successful rotation = %v", err)
	}
	if len(validAttestor.seen) != 1 || validAttestor.seen[0].TranscriptPath != PathPublicRotate {
		t.Fatalf("rotation attestation path = %+v, want %q", validAttestor.seen, PathPublicRotate)
	}
}

func TestServiceQueriesRetentionAndCloseBoundaries(t *testing.T) {
	noStore := NewService(nil, DefaultCatalog(), nil)
	if _, _, err := noStore.QueryEvents(context.Background(), QueryFilter{}); !errors.Is(err, ErrServiceUnavailable) {
		t.Fatalf("QueryEvents without store = %v, want unavailable", err)
	}
	if _, _, _, err := noStore.QueryDiagnostics(context.Background(), QueryFilter{}); !errors.Is(err, ErrServiceUnavailable) {
		t.Fatalf("QueryDiagnostics without store = %v, want unavailable", err)
	}
	if _, err := noStore.GetPolicy(context.Background()); !errors.Is(err, ErrServiceUnavailable) {
		t.Fatalf("GetPolicy without store = %v, want unavailable", err)
	}
	if _, err := noStore.GetSettings(context.Background()); !errors.Is(err, ErrServiceUnavailable) {
		t.Fatalf("GetSettings without store = %v, want unavailable", err)
	}
	if err := noStore.UpdateSettings(context.Background(), DefaultSettings()); !errors.Is(err, ErrServiceUnavailable) {
		t.Fatalf("UpdateSettings without store = %v, want unavailable", err)
	}
	if _, err := noStore.PurgeRetention(context.Background()); !errors.Is(err, ErrServiceUnavailable) {
		t.Fatalf("PurgeRetention without store = %v, want unavailable", err)
	}

	settings := DefaultSettings()
	settings.RedisCacheEnabled = true
	store := &serviceBoundaryStore{
		Store:            NewMemoryStore(DefaultCatalog()),
		settings:         &settings,
		diagnostics:      []TelemetryEnvelope{testEnvelope("cached-diagnostic", "service-query-device")},
		diagnosticsTotal: 2,
		events:           []TelemetryEnvelope{testEnvelope("queried-event", "service-query-device")},
		eventsTotal:      1,
	}
	cache := &serviceBoundaryCache{recent: []TelemetryEnvelope{testEnvelope("cached-diagnostic", "service-query-device")}}
	service := NewServiceWithSecret(store, DefaultCatalog(), cache, testAuthSecret)
	if events, total, err := service.QueryEvents(context.Background(), QueryFilter{}); err != nil || total != 1 || len(events) != 1 {
		t.Fatalf("QueryEvents = len=%d total=%d err=%v, want one event", len(events), total, err)
	}
	if diagnostics, total, source, err := service.QueryDiagnostics(context.Background(), QueryFilter{PageSize: 0}); err != nil || source != "redis_cache" || total != 2 || len(diagnostics) != 1 {
		t.Fatalf("cached QueryDiagnostics = len=%d total=%d source=%q err=%v", len(diagnostics), total, source, err)
	}
	cache.mu.Lock()
	if cache.lastLimit != 50 {
		t.Fatalf("cached diagnostics default limit = %d, want 50", cache.lastLimit)
	}
	cache.mu.Unlock()

	store.diagnosticsErr = errors.New("diagnostics query failed")
	if diagnostics, total, source, err := service.QueryDiagnostics(context.Background(), QueryFilter{}); err != nil || source != "redis_cache" || total != 1 || len(diagnostics) != 1 {
		t.Fatalf("cached fallback QueryDiagnostics = len=%d total=%d source=%q err=%v", len(diagnostics), total, source, err)
	}
	cache.recent = nil
	store.diagnosticsErr = nil
	if diagnostics, total, source, err := service.QueryDiagnostics(context.Background(), QueryFilter{DeviceID: "service-query-device"}); err != nil || source != "mysql" || total != 2 || len(diagnostics) != 1 {
		t.Fatalf("filtered QueryDiagnostics = len=%d total=%d source=%q err=%v", len(diagnostics), total, source, err)
	}
	settings.RedisCacheEnabled = false
	store.settings = &settings
	if _, _, source, err := service.QueryDiagnostics(context.Background(), QueryFilter{}); err != nil || source != "mysql" {
		t.Fatalf("disabled-cache QueryDiagnostics source=%q err=%v, want mysql", source, err)
	}
	store.settingsErr = errors.New("settings query failed")
	if _, _, _, err := service.QueryDiagnostics(context.Background(), QueryFilter{}); err == nil {
		t.Fatal("QueryDiagnostics unexpectedly ignored settings failure")
	}

	store.settingsErr = nil
	store.settings = &TelemetrySettings{}
	if policy, err := service.GetPolicy(context.Background()); err != nil || policy == nil {
		t.Fatalf("GetPolicy = %#v err=%v", policy, err)
	}
	if err := service.UpdateSettings(context.Background(), DefaultSettings()); err != nil {
		t.Fatalf("UpdateSettings = %v", err)
	}
	store.settings = &TelemetrySettings{}
	if count, err := service.PurgeRetention(context.Background()); err != nil || count != 0 {
		t.Fatalf("disabled retention = %d err=%v, want zero", count, err)
	}
	retentionSettings := &TelemetrySettings{
		RetentionDays:        2,
		RetentionMaxRows:     10,
		RetentionTimeEnabled: true,
		RetentionRowsEnabled: true,
	}
	store.settings = retentionSettings
	store.purgeCount = 3
	if count, err := service.PurgeRetention(context.Background()); err != nil || count != 3 {
		t.Fatalf("enabled retention = %d err=%v, want 3", count, err)
	}
	if store.purgeCutoff.IsZero() || store.purgeMaxRows != 10 || store.purgeBatch != 500 {
		t.Fatalf("retention arguments cutoff=%v maxRows=%d batch=%d", store.purgeCutoff, store.purgeMaxRows, store.purgeBatch)
	}

	store.closeErr = errors.New("store close failed")
	cache.closeErr = errors.New("cache close failed")
	if err := service.Close(); !errors.Is(err, store.closeErr) {
		t.Fatalf("Close error = %v, want store close error", err)
	}
	cacheOnly := &serviceBoundaryCache{closeErr: errors.New("cache-only close failed")}
	if err := NewServiceWithSecret(nil, DefaultCatalog(), cacheOnly, testAuthSecret).Close(); !errors.Is(err, cacheOnly.closeErr) {
		t.Fatalf("cache-only Close error = %v, want cache error", err)
	}
}
