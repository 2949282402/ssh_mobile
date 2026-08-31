// RelayManagementClient interface and HTTP client implementation for communicating
// with Relay's internal management API (/internal/v2/*).

package admin

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/ssh-mobile/relay/internal/telemetry"
)

var (
	ErrRelayUnavailable = errors.New("relay service unavailable")
	ErrDeviceNotFound   = errors.New("device not found")
	ErrResourceLimit    = errors.New("resource limit reached")
	ErrConflict         = errors.New("conflict")
	ErrRelayAttestation = errors.New("relay device attestation failed")
)

type RelayStatus struct {
	ServerTime        int64            `json:"server_time"`
	UptimeSeconds     int64            `json:"uptime_seconds"`
	Devices           RelayDeviceStat  `json:"devices"`
	Relay             RelayStat        `json:"relay"`
	Runtime           RelayRuntimeStat `json:"runtime"`
	PresenceAvailable bool             `json:"presence_available"`
}

type RelayDeviceStat struct {
	Enrolled int `json:"enrolled"`
	Online   int `json:"online"`
}

type RelayStat struct {
	ActiveTransfers int `json:"active_transfers"`
}

type RelayRuntimeStat struct {
	AllocatedMemMB float64 `json:"allocated_mem_mb"`
	Goroutines     int     `json:"goroutines"`
}

type RelayDevices struct {
	Items             []RelayDeviceItem `json:"items"`
	Total             int               `json:"total"`
	PresenceAvailable bool              `json:"presence_available"`
}

type RelayDeviceItem struct {
	DeviceID             string `json:"device_id"`
	Platform             string `json:"platform"`
	ProtocolVersion      uint32 `json:"protocol_version"`
	EnrolledAt           string `json:"enrolled_at"`
	Online               bool   `json:"online"`
	RemoteAddr           string `json:"remote_addr"`
	PublicKeyFingerprint string `json:"public_key_fingerprint"`
}

type EnrollmentTokenInfo struct {
	EnrollmentToken string `json:"enrollment_token"`
}

// RelayManagementClient provides typed access to Relay management capabilities.
type RelayManagementClient interface {
	Status(ctx context.Context) (RelayStatus, error)
	Devices(ctx context.Context) (RelayDevices, error)
	RevokeDevice(ctx context.Context, deviceID string) error
	EnrollmentToken(ctx context.Context) (EnrollmentTokenInfo, error)
	RotateEnrollmentToken(ctx context.Context) (EnrollmentTokenInfo, error)
}

type httpRelayManagementClient struct {
	baseURL       string
	internalToken string
	httpClient    *http.Client
}

// NewRelayManagementClient constructs a RelayManagementClient that communicates over HTTP.
func NewRelayManagementClient(baseURL, internalToken string) RelayManagementClient {
	baseURL = strings.TrimRight(baseURL, "/")
	return &httpRelayManagementClient{
		baseURL:       baseURL,
		internalToken: internalToken,
		httpClient: &http.Client{
			Timeout: 5 * time.Second,
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}
}

func (c *httpRelayManagementClient) Status(ctx context.Context) (RelayStatus, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+RelayInternalPathStatus, nil)
	if err != nil {
		return RelayStatus{}, err
	}
	req.Header.Set("Authorization", "Bearer "+c.internalToken)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return RelayStatus{}, fmt.Errorf("%w: %v", ErrRelayUnavailable, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return RelayStatus{}, mapHTTPStatusToError(resp.StatusCode)
	}

	var status RelayStatus
	if err := json.NewDecoder(resp.Body).Decode(&status); err != nil {
		return RelayStatus{}, fmt.Errorf("%w: %v", ErrRelayUnavailable, err)
	}
	return status, nil
}

func (c *httpRelayManagementClient) Devices(ctx context.Context) (RelayDevices, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+RelayInternalPathDevices, nil)
	if err != nil {
		return RelayDevices{}, err
	}
	req.Header.Set("Authorization", "Bearer "+c.internalToken)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return RelayDevices{}, fmt.Errorf("%w: %v", ErrRelayUnavailable, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return RelayDevices{}, mapHTTPStatusToError(resp.StatusCode)
	}

	var devices RelayDevices
	if err := json.NewDecoder(resp.Body).Decode(&devices); err != nil {
		return RelayDevices{}, fmt.Errorf("%w: %v", ErrRelayUnavailable, err)
	}
	return devices, nil
}

func (c *httpRelayManagementClient) RevokeDevice(ctx context.Context, deviceID string) error {
	path := fmt.Sprintf("%s%s%s/revoke", c.baseURL, RelayInternalPathRevokePrefix, url.PathEscape(deviceID))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.internalToken)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrRelayUnavailable, err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)

	if resp.StatusCode == http.StatusNoContent {
		return nil
	}
	return mapHTTPStatusToError(resp.StatusCode)
}

func (c *httpRelayManagementClient) EnrollmentToken(ctx context.Context) (EnrollmentTokenInfo, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+RelayInternalPathToken, nil)
	if err != nil {
		return EnrollmentTokenInfo{}, err
	}
	req.Header.Set("Authorization", "Bearer "+c.internalToken)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return EnrollmentTokenInfo{}, fmt.Errorf("%w: %v", ErrRelayUnavailable, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return EnrollmentTokenInfo{}, mapHTTPStatusToError(resp.StatusCode)
	}

	var info EnrollmentTokenInfo
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return EnrollmentTokenInfo{}, fmt.Errorf("%w: %v", ErrRelayUnavailable, err)
	}
	return info, nil
}

func (c *httpRelayManagementClient) RotateEnrollmentToken(ctx context.Context) (EnrollmentTokenInfo, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+RelayInternalPathRotateToken, nil)
	if err != nil {
		return EnrollmentTokenInfo{}, err
	}
	req.Header.Set("Authorization", "Bearer "+c.internalToken)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return EnrollmentTokenInfo{}, fmt.Errorf("%w: %v", ErrRelayUnavailable, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return EnrollmentTokenInfo{}, mapHTTPStatusToError(resp.StatusCode)
	}

	var info EnrollmentTokenInfo
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return EnrollmentTokenInfo{}, fmt.Errorf("%w: %v", ErrRelayUnavailable, err)
	}
	return info, nil
}

// ValidateDeviceCredential asks Relay to attest the existing device identity.
// The credential and proof are request-only and are never logged or retained
// by the Admin service.
func (c *httpRelayManagementClient) ValidateDeviceCredential(ctx context.Context, request telemetry.DeviceAttestationRequest) (telemetry.DeviceAttestation, error) {
	payload := struct {
		DeviceID        string `json:"device_id"`
		RelayCredential string `json:"relay_credential"`
		PublicKey       string `json:"public_key"`
		Timestamp       int64  `json:"timestamp"`
		Nonce           string `json:"nonce"`
		Signature       string `json:"signature"`
		TranscriptPath  string `json:"transcript_path,omitempty"`
	}{
		DeviceID:        request.DeviceID,
		RelayCredential: request.RelayCredential,
		PublicKey:       request.PublicKey,
		Timestamp:       request.Timestamp,
		Nonce:           request.Nonce,
		Signature:       request.Signature,
		TranscriptPath:  request.TranscriptPath,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return telemetry.DeviceAttestation{}, fmt.Errorf("%w: request encoding", telemetry.ErrDeviceAttestorUnavailable)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+RelayInternalPathTelemetryAttest, strings.NewReader(string(body)))
	if err != nil {
		return telemetry.DeviceAttestation{}, fmt.Errorf("%w: request creation", telemetry.ErrDeviceAttestorUnavailable)
	}
	req.Header.Set("Authorization", "Bearer "+c.internalToken)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return telemetry.DeviceAttestation{}, fmt.Errorf("%w: %w", telemetry.ErrDeviceAttestorUnavailable, ErrRelayUnavailable)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, resp.Body)
		if resp.StatusCode >= http.StatusInternalServerError {
			return telemetry.DeviceAttestation{}, fmt.Errorf("%w: %w (status %d)", telemetry.ErrDeviceAttestorUnavailable, ErrRelayUnavailable, resp.StatusCode)
		}
		return telemetry.DeviceAttestation{}, fmt.Errorf("%w: relay rejected proof", ErrRelayAttestation)
	}
	var result struct {
		DeviceID             string `json:"device_id"`
		EnrollmentGeneration int64  `json:"enrollment_generation"`
		ProtocolVersion      uint32 `json:"protocol_version"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64*1024)).Decode(&result); err != nil {
		return telemetry.DeviceAttestation{}, fmt.Errorf("%w: %w", telemetry.ErrDeviceAttestorUnavailable, ErrRelayUnavailable)
	}
	return telemetry.DeviceAttestation{
		DeviceID:             result.DeviceID,
		EnrollmentGeneration: result.EnrollmentGeneration,
		ProtocolVersion:      result.ProtocolVersion,
	}, nil
}

func mapHTTPStatusToError(statusCode int) error {
	switch statusCode {
	case http.StatusNotFound:
		return ErrDeviceNotFound
	case http.StatusTooManyRequests:
		return ErrResourceLimit
	case http.StatusConflict:
		return ErrConflict
	default:
		return ErrRelayUnavailable
	}
}
