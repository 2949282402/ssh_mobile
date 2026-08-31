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
	// ErrPolicyVersionConflict prevents a stale Admin writer from replacing a
	// newer server-owned policy. Policy versions are strictly monotonic.
	ErrPolicyVersionConflict = errors.New("telemetry policy version conflict")
	// ErrEnrollmentGenerationConflict prevents a revoked credential from being
	// reactivated by a stale Relay attestation.
	ErrEnrollmentGenerationConflict = errors.New("telemetry enrollment generation conflict")
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

func deviceTokenMessage(deviceID string, generation, expEpoch int64) []byte {
	return []byte("telemetry:token:" + deviceID + ":" + strconv.FormatInt(generation, 10) + ":" + strconv.FormatInt(expEpoch, 10))
}

func (s *Service) deviceCredential(ctx context.Context, deviceID string) (DeviceCredential, error) {
	hash, err := s.store.GetDeviceCredential(ctx, deviceID)
	if err != nil {
		return DeviceCredential{}, err
	}
	credential := DeviceCredential{SecretHash: hash}
	if metadataStore, ok := s.store.(credentialMetadataStore); ok {
		metadata, metadataErr := metadataStore.GetDeviceCredentialMetadata(ctx, deviceID)
		if metadataErr != nil {
			return DeviceCredential{}, metadataErr
		}
		// Keep the Store interface's lookup authoritative for compatibility with
		// wrappers that decorate or audit the legacy credential method.
		if strings.TrimSpace(metadata.SecretHash) == "" {
			metadata.SecretHash = hash
		}
		credential = metadata
	}
	return credential, nil
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

	credential, err := s.deviceCredential(ctx, deviceID)
	if err != nil {
		if errors.Is(err, ErrDeviceCredentialNotFound) {
			return "", 0, ErrDeviceNotRegistered
		}
		return "", 0, fmt.Errorf("%w: unable to verify device credential: %v", ErrServiceUnavailable, err)
	}
	if credential.RevokedAt != nil || strings.TrimSpace(credential.SecretHash) == "" {
		return "", 0, ErrDeviceNotRegistered
	}

	if !VerifyDeviceProof(deviceID, credential.SecretHash, proof, expEpoch) {
		return "", 0, fmt.Errorf("%w: invalid device proof", ErrAuthFailed)
	}

	token, exp := s.generateDeviceToken(deviceID, credential.EnrollmentGeneration, DefaultTokenTTL)
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

func (s *Service) generateDeviceToken(deviceID string, generation int64, expiryDuration time.Duration) (string, int64) {
	if generation <= 0 {
		return s.GenerateDeviceToken(deviceID, expiryDuration)
	}
	if !isValidDeviceID(deviceID) {
		return "", 0
	}
	if expiryDuration <= 0 {
		expiryDuration = DefaultTokenTTL
	}
	exp := time.Now().UTC().Add(expiryDuration).Unix()
	return s.signTokenWithGeneration(deviceID, generation, exp)
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

func (s *Service) signTokenWithGeneration(deviceID string, generation, expEpoch int64) (string, int64) {
	if s.tokenKey == nil || !isValidDeviceID(deviceID) || generation <= 0 || expEpoch <= 0 {
		return "", 0
	}
	mac := hmac.New(sha256.New, s.tokenKey)
	mac.Write(deviceTokenMessage(deviceID, generation, expEpoch))
	sig := hex.EncodeToString(mac.Sum(nil))
	return fmt.Sprintf("%d.%d.%s", expEpoch, generation, sig), expEpoch
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
	if len(parts) != 2 && len(parts) != 3 {
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
	if len(parts) == 3 {
		generation, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil || generation <= 0 {
			return false
		}
		mac.Write(deviceTokenMessage(deviceID, generation, exp))
	} else {
		mac.Write(deviceAuthMessage(deviceID, exp))
	}
	expectedSig := hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(expectedSig), []byte(parts[len(parts)-1]))
}

// VerifyDeviceTokenAt performs cryptographic verification and, when the
// backing store supports credential metadata, checks the current Relay
// enrollment generation and revocation marker. This is the request-path check
// used by public ingest, so a Relay/admin revoke invalidates existing tokens.
func (s *Service) VerifyDeviceTokenAt(ctx context.Context, deviceID, token string) bool {
	if !s.VerifyDeviceToken(deviceID, token) {
		return false
	}
	metadataStore, ok := s.store.(credentialMetadataStore)
	if !ok {
		return true
	}
	credential, err := metadataStore.GetDeviceCredentialMetadata(ctx, deviceID)
	if err != nil || credential.RevokedAt != nil {
		return false
	}
	parts := strings.Split(token, ".")
	if len(parts) == 2 {
		return credential.EnrollmentGeneration <= 0
	}
	generation, err := strconv.ParseInt(parts[1], 10, 64)
	return err == nil && generation > 0 && generation == credential.EnrollmentGeneration
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
	generation := attestation.EnrollmentGeneration
	if generation < 0 {
		generation = 0
	}

	secretBytes := make([]byte, 32)
	if _, err := rand.Read(secretBytes); err != nil {
		return TelemetryEnrollmentResponse{}, ErrServiceUnavailable
	}
	secret := hex.EncodeToString(secretBytes)
	var storeErr error
	if rotate {
		if _, err := s.deviceCredential(ctx, request.DeviceID); err != nil {
			if errors.Is(err, ErrDeviceCredentialNotFound) {
				return TelemetryEnrollmentResponse{}, ErrEnrollmentCredentialMissing
			}
			return TelemetryEnrollmentResponse{}, ErrServiceUnavailable
		}
		if metadataStore, ok := s.store.(credentialMetadataStore); ok && generation > 0 {
			storeErr = metadataStore.RegisterDeviceCredentialWithGeneration(ctx, request.DeviceID, hashSecret(secret), generation)
		} else {
			storeErr = s.store.RegisterDeviceCredential(ctx, request.DeviceID, hashSecret(secret))
		}
	} else {
		if metadataStore, ok := s.store.(credentialMetadataStore); ok && generation > 0 {
			storeErr = metadataStore.CreateDeviceCredentialWithGeneration(ctx, request.DeviceID, hashSecret(secret), generation)
		} else {
			storeErr = creator.CreateDeviceCredential(ctx, request.DeviceID, hashSecret(secret))
		}
	}
	if storeErr != nil {
		if errors.Is(storeErr, ErrDeviceCredentialAlreadyExists) || errors.Is(storeErr, ErrEnrollmentGenerationConflict) {
			return TelemetryEnrollmentResponse{}, ErrEnrollmentAlreadyExists
		}
		return TelemetryEnrollmentResponse{}, ErrServiceUnavailable
	}
	return TelemetryEnrollmentResponse{DeviceID: request.DeviceID, Secret: secret}, nil
}

// RevokeDeviceCredential invalidates telemetry credentials without deleting
// their generation metadata. Admin calls this as part of device revocation;
// subsequent bearer-token checks fail closed even if an old token is replayed.
func (s *Service) RevokeDeviceCredential(ctx context.Context, deviceID string) error {
	if s == nil || s.store == nil {
		return ErrServiceUnavailable
	}
	metadataStore, ok := s.store.(credentialMetadataStore)
	if !ok {
		return ErrServiceUnavailable
	}
	return metadataStore.RevokeDeviceCredential(ctx, deviceID)
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
