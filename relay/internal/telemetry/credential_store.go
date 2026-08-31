package telemetry

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// credentialMetadataStore is an additive capability implemented by durable
// stores. Keeping it separate from Store preserves source compatibility for
// hermetic callers while production stores can bind credentials and tokens to
// Relay enrollment generations.
type credentialMetadataStore interface {
	CreateDeviceCredentialWithGeneration(context.Context, string, string, int64) error
	RegisterDeviceCredentialWithGeneration(context.Context, string, string, int64) error
	GetDeviceCredentialMetadata(context.Context, string) (DeviceCredential, error)
	RevokeDeviceCredential(context.Context, string) error
}

// CreateDeviceCredential persists a credential hash exactly once. It is
// separate from RegisterDeviceCredential because public enrollment must never
// silently rotate a credential after a replay or lost response.
func (m *MemoryStore) CreateDeviceCredential(ctx context.Context, deviceID, secretHash string) error {
	return m.CreateDeviceCredentialWithGeneration(ctx, deviceID, secretHash, 0)
}

// CreateDeviceCredentialWithGeneration creates a credential bound to the
// Relay enrollment generation. A revoked credential may be replaced only by a
// strictly newer generation, which prevents replaying an old attestation.
func (m *MemoryStore) CreateDeviceCredentialWithGeneration(ctx context.Context, deviceID, secretHash string, generation int64) error {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return err
		}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if strings.TrimSpace(deviceID) == "" || strings.TrimSpace(secretHash) == "" {
		return fmt.Errorf("invalid deviceId or secretHash")
	}
	if existing, exists := m.credentialMeta[deviceID]; exists {
		if existing.RevokedAt != nil && generation > existing.EnrollmentGeneration {
			m.credentials[deviceID] = secretHash
			m.credentialMeta[deviceID] = DeviceCredential{SecretHash: secretHash, EnrollmentGeneration: generation}
			return nil
		}
		return ErrDeviceCredentialAlreadyExists
	}
	if _, exists := m.credentials[deviceID]; exists {
		return ErrDeviceCredentialAlreadyExists
	}
	m.credentials[deviceID] = secretHash
	m.credentialMeta[deviceID] = DeviceCredential{SecretHash: secretHash, EnrollmentGeneration: generation}
	return nil
}

func (m *MemoryStore) RegisterDeviceCredential(ctx context.Context, deviceID, secretHash string) error {
	return m.RegisterDeviceCredentialWithGeneration(ctx, deviceID, secretHash, 0)
}

// RegisterDeviceCredentialWithGeneration rotates a credential at the newly
// attested Relay generation and clears any prior revocation marker.
func (m *MemoryStore) RegisterDeviceCredentialWithGeneration(ctx context.Context, deviceID, secretHash string, generation int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if strings.TrimSpace(deviceID) == "" || strings.TrimSpace(secretHash) == "" {
		return fmt.Errorf("invalid deviceId or secretHash")
	}
	if existing, exists := m.credentialMeta[deviceID]; exists {
		if generation < existing.EnrollmentGeneration ||
			(existing.RevokedAt != nil && generation <= existing.EnrollmentGeneration) {
			return ErrEnrollmentGenerationConflict
		}
	}
	m.credentials[deviceID] = secretHash
	m.credentialMeta[deviceID] = DeviceCredential{SecretHash: secretHash, EnrollmentGeneration: generation}
	return nil
}

func (m *MemoryStore) GetDeviceCredential(ctx context.Context, deviceID string) (string, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	hash, ok := m.credentials[deviceID]
	if !ok {
		return "", fmt.Errorf("%w: %s", ErrDeviceCredentialNotFound, deviceID)
	}
	return hash, nil
}

// GetDeviceCredentialMetadata returns the credential state used for
// generation-bound bearer-token verification.
func (m *MemoryStore) GetDeviceCredentialMetadata(ctx context.Context, deviceID string) (DeviceCredential, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if credential, ok := m.credentialMeta[deviceID]; ok {
		return credential, nil
	}
	hash, ok := m.credentials[deviceID]
	if !ok {
		return DeviceCredential{}, fmt.Errorf("%w: %s", ErrDeviceCredentialNotFound, deviceID)
	}
	return DeviceCredential{SecretHash: hash}, nil
}

// RevokeDeviceCredential invalidates telemetry authentication without
// deleting the row, so a later newer Relay enrollment can be distinguished
// from a replay of the revoked generation.
func (m *MemoryStore) RevokeDeviceCredential(ctx context.Context, deviceID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	credential, ok := m.credentialMeta[deviceID]
	if !ok {
		hash, exists := m.credentials[deviceID]
		if !exists {
			return fmt.Errorf("%w: %s", ErrDeviceCredentialNotFound, deviceID)
		}
		credential = DeviceCredential{SecretHash: hash}
	}
	if credential.RevokedAt == nil {
		now := time.Now().UTC()
		credential.RevokedAt = &now
	}
	m.credentialMeta[deviceID] = credential
	return nil
}
