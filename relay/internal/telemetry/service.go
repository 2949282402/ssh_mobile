// Telemetry Service orchestrating Store, Catalog, Cache, and Retention.

package telemetry

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

var validDeviceIDRegex = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)

// isValidDeviceID validates that a device identifier contains only safe ASCII
// characters (alphanumeric, dot, underscore, dash) and is within 1-128 bytes.
// The bound matches the Relay bootstrap identity contract (device_id ≤ 128
// bytes) and the telemetry MySQL VARCHAR(128) columns; the strict character set
// keeps delimiters such as ':' out of auth token transcripts to prevent
// delimiter-collision forgery.
func isValidDeviceID(deviceID string) bool {
	return validDeviceIDRegex.MatchString(deviceID)
}

// DefaultTokenTTL is the lifetime of issued device auth tokens.
const DefaultTokenTTL = 2 * time.Hour

// Auth skew tolerance for AuthenticateDevice expEpoch validation.
const maxAuthEpochSkewSeconds = 120

// Sentinel errors surfaced by the Service and mapped to HTTP responses by handlers.
var (
	// ErrServiceUnavailable indicates the telemetry backend is not usable
	// (store missing, signing key missing, or backing store failure).
	ErrServiceUnavailable = errors.New("telemetry service unavailable")
	// ErrDeviceNotRegistered indicates the device has no enrolled credential.
	ErrDeviceNotRegistered = errors.New("device not registered")
	// ErrAuthFailed indicates the device proof or token did not verify.
	ErrAuthFailed = errors.New("device authentication failed")
	// ErrDeviceCredentialNotFound is wrapped by stores when no credential exists.
	ErrDeviceCredentialNotFound = errors.New("device credential not found")
	// ErrEnrollmentInvalidRequest indicates a malformed device proof request.
	ErrEnrollmentInvalidRequest = errors.New("invalid telemetry enrollment request")
	// ErrEnrollmentProofFailed indicates that Relay did not attest the existing
	// device identity. The underlying reason is intentionally not exposed.
	ErrEnrollmentProofFailed = errors.New("telemetry enrollment proof failed")
	// ErrDeviceAttestorUnavailable distinguishes a Relay outage from a rejected
	// proof without exposing credential-bearing response details.
	ErrDeviceAttestorUnavailable = errors.New("device attestor unavailable")
	// ErrEnrollmentAlreadyExists prevents implicit credential rotation on
	// retries, including retries after a client lost the first response.
	ErrEnrollmentAlreadyExists = errors.New("telemetry credential already enrolled")
	// ErrEnrollmentCredentialMissing indicates that explicit rotation has no
	// existing telemetry credential to replace.
	ErrEnrollmentCredentialMissing = errors.New("telemetry credential is not enrolled")
	// ErrIngestBatchTooLarge is returned before validation or storage allocation
	// when a direct caller exceeds the bounded public-ingest batch contract.
	ErrIngestBatchTooLarge = errors.New("telemetry ingest batch exceeds maximum size")
)

type credentialCreator interface {
	CreateDeviceCredential(context.Context, string, string) error
}

// Service aggregates telemetry persistence, contract validation, caching and auth.
type Service struct {
	store         Store
	catalog       *Catalog
	redisCache    RedisCache
	tokenKey      []byte
	ingestMetrics *ingestMetrics
	mu            sync.RWMutex
}

// NewService creates a Service without a token signing secret. The service is
// fail-closed: token issuance and ingest verification return ErrServiceUnavailable
// until a signing secret is supplied via NewServiceWithSecret.
func NewService(store Store, catalog *Catalog, redisCache RedisCache) *Service {
	return NewServiceWithSecret(store, catalog, redisCache, "")
}

// NewServiceWithSecret creates a Service with the given auth secret used to sign
// device tokens. If authSecret is empty or shorter than 16 characters the service
// is fail-closed: s.tokenKey stays nil and auth/ingest return 503.
func NewServiceWithSecret(store Store, catalog *Catalog, redisCache RedisCache, authSecret string) *Service {
	if catalog == nil {
		catalog = DefaultCatalog()
	}
	if redisCache == nil {
		redisCache = &NoopRedisCache{}
	}
	trimmedSecret := strings.TrimSpace(authSecret)
	var tokenKey []byte
	if len(trimmedSecret) >= 16 {
		tokenKey = []byte(hashSecret(trimmedSecret))
	}
	return &Service{
		store:         store,
		catalog:       catalog,
		redisCache:    redisCache,
		tokenKey:      tokenKey,
		ingestMetrics: newIngestMetrics(),
	}
}

// Available reports whether the service can authenticate devices and ingest data:
// a backing store and a configured token signing secret are both required.
func (s *Service) Available() bool {
	return s.StoreAvailable() && s.tokenKey != nil
}

// StoreAvailable reports whether a backing telemetry store is wired. Admin query
// and policy endpoints need a store but not the token signing secret.
func (s *Service) StoreAvailable() bool {
	return s.store != nil
}

func hashSecret(secret string) string {
	h := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(h[:])
}

// deviceAuthMessage returns the canonical proof message signed by device secrets
// and token signing keys: "telemetry:auth:<deviceID>:<expEpoch>".
func deviceAuthMessage(deviceID string, expEpoch int64) []byte {
	return []byte("telemetry:auth:" + deviceID + ":" + strconv.FormatInt(expEpoch, 10))
}

// VerifyDeviceProof checks that proof is a valid HMAC-SHA256 over the auth
// message using the device's stored credential hash as the key.
func VerifyDeviceProof(deviceID, storedCredentialHash, proof string, expEpoch int64) bool {
	if !isValidDeviceID(deviceID) || strings.TrimSpace(storedCredentialHash) == "" || strings.TrimSpace(proof) == "" || expEpoch <= 0 {
		return false
	}
	mac := hmac.New(sha256.New, []byte(storedCredentialHash))
	mac.Write(deviceAuthMessage(deviceID, expEpoch))
	expected := hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(expected), []byte(strings.TrimSpace(proof)))
}

// AuthenticateDevice verifies a device's proof-of-possession of its enrolled
// secret and issues a short-lived scoped token.
//
//   - expEpoch must be within 120s of server now, else ErrAuthFailed.
//   - The device's stored credential hash is required; missing credentials are
//     always rejected (ErrDeviceNotRegistered). No token is ever issued without
//     valid proof against a registered credential.
//   - proof is hex(HMAC-SHA256(key=storedHash, data="telemetry:auth:"+deviceID+":"+expEpoch)).
func (s *Service) AuthenticateDevice(ctx context.Context, deviceID, proof string, expEpoch int64) (string, int64, error) {
	if s.tokenKey == nil || s.store == nil {
		return "", 0, ErrServiceUnavailable
	}
	if !isValidDeviceID(deviceID) {
		return "", 0, fmt.Errorf("%w: invalid deviceId format", ErrAuthFailed)
	}

	now := time.Now().UTC().Unix()
	if expEpoch <= 0 || expEpoch < now-maxAuthEpochSkewSeconds || expEpoch > now+maxAuthEpochSkewSeconds {
		return "", 0, fmt.Errorf("%w: expEpoch outside allowed skew window", ErrAuthFailed)
	}

	credHash, err := s.store.GetDeviceCredential(ctx, deviceID)
	if err != nil {
		if errors.Is(err, ErrDeviceCredentialNotFound) {
			return "", 0, ErrDeviceNotRegistered
		}
		return "", 0, fmt.Errorf("%w: unable to verify device credential: %v", ErrServiceUnavailable, err)
	}
	if strings.TrimSpace(credHash) == "" {
		return "", 0, ErrDeviceNotRegistered
	}

	if !VerifyDeviceProof(deviceID, credHash, proof, expEpoch) {
		return "", 0, fmt.Errorf("%w: invalid device proof", ErrAuthFailed)
	}

	token, exp := s.GenerateDeviceToken(deviceID, DefaultTokenTTL)
	expiresIn := exp - time.Now().UTC().Unix()
	if expiresIn <= 0 {
		expiresIn = int64(DefaultTokenTTL.Seconds())
	}
	return token, expiresIn, nil
}

// GenerateDeviceToken creates a scoped authentication token for a device with an
// expiration timestamp. A nil tokenKey produces an empty token (fail-closed).
func (s *Service) GenerateDeviceToken(deviceID string, expiryDuration time.Duration) (string, int64) {
	if !isValidDeviceID(deviceID) {
		return "", 0
	}
	if expiryDuration <= 0 {
		expiryDuration = DefaultTokenTTL
	}
	exp := time.Now().UTC().Add(expiryDuration).Unix()
	return s.signToken(deviceID, exp)
}

func (s *Service) signToken(deviceID string, expEpoch int64) (string, int64) {
	if s.tokenKey == nil || !isValidDeviceID(deviceID) || expEpoch <= 0 {
		return "", 0
	}
	mac := hmac.New(sha256.New, s.tokenKey)
	mac.Write(deviceAuthMessage(deviceID, expEpoch))
	sig := hex.EncodeToString(mac.Sum(nil))
	return fmt.Sprintf("%d.%s", expEpoch, sig), expEpoch
}

// VerifyDeviceToken checks whether the bearer token matches the device identity,
// has not expired, and was signed with the configured auth secret. It requires a
// configured signing key and returns false for any legacy single-part token.
func (s *Service) VerifyDeviceToken(deviceID, token string) bool {
	if s.tokenKey == nil {
		return false
	}
	if !isValidDeviceID(deviceID) || strings.TrimSpace(token) == "" {
		return false
	}
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return false
	}

	exp, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || exp <= 0 {
		return false
	}

	// Token is valid only while strictly in the future.
	if time.Now().UTC().Unix() >= exp {
		return false
	}

	mac := hmac.New(sha256.New, s.tokenKey)
	mac.Write(deviceAuthMessage(deviceID, exp))
	expectedSig := hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(expectedSig), []byte(parts[1]))
}

// EnrollDevice verifies an existing Relay device identity and creates one
// telemetry credential. The plaintext secret is returned only once; only its
// SHA-256-derived hash is handed to the backing store. The creator capability
// is intentionally separate from RegisterDeviceCredential, which is reserved
// for explicit proof-bound rotation.
func (s *Service) EnrollDevice(ctx context.Context, request TelemetryEnrollmentRequest, attestor DeviceAttestor) (TelemetryEnrollmentResponse, error) {
	return s.issueDeviceCredential(ctx, request, attestor, false)
}

// RotateDevice explicitly replaces an existing telemetry credential after a
// fresh Relay proof. It is intentionally a separate route from EnrollDevice so
// retries and replayed proofs never rotate a credential implicitly.
func (s *Service) RotateDevice(ctx context.Context, request TelemetryEnrollmentRequest, attestor DeviceAttestor) (TelemetryEnrollmentResponse, error) {
	if s == nil || !s.Available() {
		return TelemetryEnrollmentResponse{}, ErrServiceUnavailable
	}
	if err := validEnrollmentRequestForService(request, attestor); err != nil {
		return TelemetryEnrollmentResponse{}, err
	}
	return s.issueDeviceCredential(ctx, request, attestor, true)
}

func (s *Service) issueDeviceCredential(ctx context.Context, request TelemetryEnrollmentRequest, attestor DeviceAttestor, rotate bool) (TelemetryEnrollmentResponse, error) {
	if s == nil || !s.Available() {
		return TelemetryEnrollmentResponse{}, ErrServiceUnavailable
	}
	if err := validEnrollmentRequestForService(request, attestor); err != nil {
		return TelemetryEnrollmentResponse{}, err
	}
	transcriptPath := PathPublicEnroll
	if rotate {
		transcriptPath = PathPublicRotate
	}
	var creator credentialCreator
	if candidate, ok := s.store.(credentialCreator); ok {
		creator = candidate
	} else if !rotate {
		return TelemetryEnrollmentResponse{}, ErrServiceUnavailable
	}

	attestation, err := attestor.ValidateDeviceCredential(ctx, DeviceAttestationRequest{
		DeviceID:        request.DeviceID,
		RelayCredential: request.RelayCredential,
		PublicKey:       request.PublicKey,
		Timestamp:       request.Timestamp,
		Nonce:           request.Nonce,
		Signature:       request.Signature,
		TranscriptPath:  transcriptPath,
	})
	if err != nil {
		if errors.Is(err, ErrDeviceAttestorUnavailable) {
			return TelemetryEnrollmentResponse{}, ErrServiceUnavailable
		}
		return TelemetryEnrollmentResponse{}, ErrEnrollmentProofFailed
	}
	if attestation.DeviceID != request.DeviceID {
		return TelemetryEnrollmentResponse{}, ErrEnrollmentProofFailed
	}

	secretBytes := make([]byte, 32)
	if _, err := rand.Read(secretBytes); err != nil {
		return TelemetryEnrollmentResponse{}, ErrServiceUnavailable
	}
	secret := hex.EncodeToString(secretBytes)
	var storeErr error
	if rotate {
		if _, err := s.store.GetDeviceCredential(ctx, request.DeviceID); err != nil {
			if errors.Is(err, ErrDeviceCredentialNotFound) {
				return TelemetryEnrollmentResponse{}, ErrEnrollmentCredentialMissing
			}
			return TelemetryEnrollmentResponse{}, ErrServiceUnavailable
		}
		storeErr = s.store.RegisterDeviceCredential(ctx, request.DeviceID, hashSecret(secret))
	} else {
		storeErr = creator.CreateDeviceCredential(ctx, request.DeviceID, hashSecret(secret))
	}
	if storeErr != nil {
		if errors.Is(storeErr, ErrDeviceCredentialAlreadyExists) {
			return TelemetryEnrollmentResponse{}, ErrEnrollmentAlreadyExists
		}
		return TelemetryEnrollmentResponse{}, ErrServiceUnavailable
	}
	return TelemetryEnrollmentResponse{DeviceID: request.DeviceID, Secret: secret}, nil
}

func validEnrollmentRequestForService(request TelemetryEnrollmentRequest, attestor DeviceAttestor) error {
	if attestor == nil {
		return ErrServiceUnavailable
	}
	if !validEnrollmentRequest(request) {
		return ErrEnrollmentInvalidRequest
	}
	return nil
}

func validEnrollmentRequest(request TelemetryEnrollmentRequest) bool {
	return isValidDeviceID(request.DeviceID) &&
		strings.TrimSpace(request.DeviceID) == request.DeviceID &&
		strings.TrimSpace(request.RelayCredential) != "" &&
		strings.TrimSpace(request.PublicKey) != "" &&
		request.Timestamp > 0 &&
		strings.TrimSpace(request.Nonce) != "" &&
		strings.TrimSpace(request.Signature) != ""
}

func (s *Service) QueryEvents(ctx context.Context, filter QueryFilter) ([]TelemetryEnvelope, int, error) {
	if s.store == nil {
		return nil, 0, ErrServiceUnavailable
	}
	return s.store.QueryEvents(ctx, filter)
}

func (s *Service) QueryDiagnostics(ctx context.Context, filter QueryFilter) ([]TelemetryEnvelope, int, string, error) {
	if s.store == nil {
		return nil, 0, "", ErrServiceUnavailable
	}
	settings, err := s.store.GetSettings(ctx)
	if err != nil {
		return nil, 0, "", err
	}
	canUseRedis := (settings == nil || settings.RedisCacheEnabled) &&
		filter.DeviceID == "" &&
		filter.TraceID == "" &&
		filter.EventName == "" &&
		filter.Feature == "" &&
		filter.ErrorCode == "" &&
		filter.Severity == "" &&
		filter.Platform == "" &&
		filter.ReleaseChannel == "" &&
		filter.AppVersion == "" &&
		filter.StartTime.IsZero() &&
		filter.EndTime.IsZero() &&
		(filter.TimeRange == "" || filter.TimeRange == "all") &&
		filter.Page <= 1

	if canUseRedis {
		limit := filter.PageSize
		if limit <= 0 {
			limit = 50
		}
		cached, err := s.redisCache.GetRecentDiagnostics(ctx, limit)
		if err == nil && len(cached) > 0 {
			// Query real total count from store for accurate pagination
			_, total, err := s.store.QueryDiagnostics(ctx, QueryFilter{RecordType: RecordTypeDiagnostic, PageSize: 1})
			if err == nil && total >= len(cached) {
				return cached, total, "redis_cache", nil
			}
			return cached, len(cached), "redis_cache", nil
		}
	}

	// Fallback to MySQL Store
	records, total, err := s.store.QueryDiagnostics(ctx, filter)
	if err != nil {
		return nil, 0, "mysql", err
	}
	return records, total, "mysql", nil
}

func (s *Service) GetPolicy(ctx context.Context) (*TelemetryUploadPolicy, error) {
	settings, err := s.GetSettings(ctx)
	if err != nil {
		return nil, err
	}
	return &settings.Policy, nil
}

func (s *Service) GetSettings(ctx context.Context) (*TelemetrySettings, error) {
	if s.store == nil {
		return nil, ErrServiceUnavailable
	}
	return s.store.GetSettings(ctx)
}

func (s *Service) UpdateSettings(ctx context.Context, settings TelemetrySettings) error {
	if s.store == nil {
		return ErrServiceUnavailable
	}
	return s.store.SaveSettings(ctx, settings)
}

// PurgeRetention executes one retention cycle.
func (s *Service) PurgeRetention(ctx context.Context) (int, error) {
	if s.store == nil {
		return 0, ErrServiceUnavailable
	}
	settings, err := s.store.GetSettings(ctx)
	if err != nil {
		return 0, err
	}

	var cutoff time.Time
	if settings.RetentionTimeEnabled && settings.RetentionDays > 0 {
		cutoff = time.Now().UTC().Add(-time.Duration(settings.RetentionDays) * 24 * time.Hour)
	}

	maxRows := 0
	if settings.RetentionRowsEnabled && settings.RetentionMaxRows > 0 {
		maxRows = settings.RetentionMaxRows
	}

	if cutoff.IsZero() && maxRows == 0 {
		return 0, nil
	}

	return s.store.PurgeRetention(ctx, cutoff, maxRows, 500)
}

// Close closes the underlying store and cache resources.
func (s *Service) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var firstErr error
	if s.store != nil {
		if err := s.store.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	if s.redisCache != nil {
		if err := s.redisCache.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}
