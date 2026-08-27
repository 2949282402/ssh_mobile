// Event and error code catalog validation and registry.

package telemetry

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
)

type AllowedProperty struct {
	Name     string `json:"name"`
	Type     string `json:"type"`
	Required bool   `json:"required"`
}

type EventDefinition struct {
	Name              string            `json:"name"`
	Version           int               `json:"version"`
	RecordType        RecordType        `json:"recordType"`
	Feature           string            `json:"feature"`
	Severity          Severity          `json:"severity"`
	Description       string            `json:"description"`
	AllowedProperties []AllowedProperty `json:"allowedProperties"`
}

type ErrorCodeDefinition struct {
	Code            string `json:"code"`
	Category        string `json:"category"`
	TerminalFailure bool   `json:"terminalFailure"`
	Description     string `json:"description"`
}

type eventsPayload struct {
	Version string            `json:"version"`
	Events  []EventDefinition `json:"events"`
}

type errorCodesPayload struct {
	Version    string                `json:"version"`
	ErrorCodes []ErrorCodeDefinition `json:"errorCodes"`
}

// Catalog holds validated event and error definitions.
type Catalog struct {
	mu         sync.RWMutex
	events     map[string]EventDefinition
	errorCodes map[string]ErrorCodeDefinition
}

// NewCatalog creates an empty Catalog.
func NewCatalog() *Catalog {
	return &Catalog{
		events:     make(map[string]EventDefinition),
		errorCodes: make(map[string]ErrorCodeDefinition),
	}
}

// LoadCatalogFromFiles reads events and error codes JSON files.
func LoadCatalogFromFiles(eventsPath, errorsPath string) (*Catalog, error) {
	eventsData, err := os.ReadFile(eventsPath)
	if err != nil {
		return nil, fmt.Errorf("read events file: %w", err)
	}

	errorsData, err := os.ReadFile(errorsPath)
	if err != nil {
		return nil, fmt.Errorf("read error codes file: %w", err)
	}

	var ep eventsPayload
	if err := json.Unmarshal(eventsData, &ep); err != nil {
		return nil, fmt.Errorf("unmarshal events JSON: %w", err)
	}

	var ecp errorCodesPayload
	if err := json.Unmarshal(errorsData, &ecp); err != nil {
		return nil, fmt.Errorf("unmarshal error codes JSON: %w", err)
	}

	c := NewCatalog()
	for _, ev := range ep.Events {
		c.events[ev.Name] = ev
	}
	for _, ec := range ecp.ErrorCodes {
		c.errorCodes[ec.Code] = ec
	}

	return c, nil
}

// RegisterEvent adds or updates an event definition in the catalog.
func (c *Catalog) RegisterEvent(def EventDefinition) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.events[def.Name] = def
}

// RegisterErrorCode adds or updates an error code definition in the catalog.
func (c *Catalog) RegisterErrorCode(def ErrorCodeDefinition) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.errorCodes[def.Code] = def
}

// GetEvent retrieves an event definition by name.
func (c *Catalog) GetEvent(name string) (EventDefinition, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	def, ok := c.events[name]
	return def, ok
}

// GetErrorCode retrieves an error code definition by code.
func (c *Catalog) GetErrorCode(code string) (ErrorCodeDefinition, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	def, ok := c.errorCodes[code]
	return def, ok
}

// ValidateEvent checks if event name, version, and properties conform to catalog rules.
func (c *Catalog) ValidateEvent(name string, version int, properties map[string]any) error {
	c.mu.RLock()
	def, ok := c.events[name]
	c.mu.RUnlock()

	if !ok {
		return fmt.Errorf("unregistered event name: %q", name)
	}

	if version != def.Version {
		return fmt.Errorf("event %q version mismatch: expected %d, got %d", name, def.Version, version)
	}

	// Build map of allowed property names
	allowed := make(map[string]AllowedProperty, len(def.AllowedProperties))
	for _, p := range def.AllowedProperties {
		allowed[p.Name] = p
	}

	// Verify required properties
	for _, p := range def.AllowedProperties {
		if p.Required {
			if _, exists := properties[p.Name]; !exists {
				return fmt.Errorf("missing required property %q for event %q", p.Name, name)
			}
		}
	}

	// Verify all provided properties are allowed and not undeclared
	for k := range properties {
		if _, exists := allowed[k]; !exists {
			return fmt.Errorf("unregistered property %q for event %q", k, name)
		}
	}

	return nil
}

// ValidateErrorCode checks if an error code is registered.
func (c *Catalog) ValidateErrorCode(code string) error {
	c.mu.RLock()
	_, ok := c.errorCodes[code]
	c.mu.RUnlock()

	if !ok {
		return fmt.Errorf("unregistered error code: %q", code)
	}
	return nil
}

// DefaultCatalog returns a pre-populated Catalog with all standard core events.
func DefaultCatalog() *Catalog {
	c := NewCatalog()
	// Populate default events
	events := []EventDefinition{
		{
			Name:        "app.lifecycle.started",
			Version:     1,
			RecordType:  RecordTypeAnalytics,
			Feature:     "app",
			Severity:    SeverityInfo,
			Description: "App started",
			AllowedProperties: []AllowedProperty{
				{Name: "start_type", Type: "string"},
				{Name: "cold_start", Type: "boolean"},
			},
		},
		{
			Name:        "app.lifecycle.backgrounded",
			Version:     1,
			RecordType:  RecordTypeAnalytics,
			Feature:     "app",
			Severity:    SeverityInfo,
			Description: "App backgrounded",
			AllowedProperties: []AllowedProperty{
				{Name: "active_sessions", Type: "integer"},
			},
		},
		{
			Name:        "app.lifecycle.foregrounded",
			Version:     1,
			RecordType:  RecordTypeAnalytics,
			Feature:     "app",
			Severity:    SeverityInfo,
			Description: "App foregrounded",
			AllowedProperties: []AllowedProperty{
				{Name: "background_duration_ms", Type: "integer"},
			},
		},
		{
			Name:        "network.quic.connected",
			Version:     1,
			RecordType:  RecordTypeAnalytics,
			Feature:     "network",
			Severity:    SeverityInfo,
			Description: "QUIC connected",
			AllowedProperties: []AllowedProperty{
				{Name: "rtt_ms", Type: "integer"},
				{Name: "protocol_version", Type: "string"},
			},
		},
		{
			Name:        "network.quic.failed",
			Version:     1,
			RecordType:  RecordTypeDiagnostic,
			Feature:     "network",
			Severity:    SeverityWarn,
			Description: "QUIC failed",
			AllowedProperties: []AllowedProperty{
				{Name: "reason", Type: "string"},
				{Name: "fallback_used", Type: "boolean"},
			},
		},
		{
			Name:        "network.relay.connected",
			Version:     1,
			RecordType:  RecordTypeAnalytics,
			Feature:     "network",
			Severity:    SeverityInfo,
			Description: "Relay connected",
			AllowedProperties: []AllowedProperty{
				{Name: "relay_region", Type: "string"},
			},
		},
		{
			Name:        "network.relay.fallback",
			Version:     1,
			RecordType:  RecordTypeDiagnostic,
			Feature:     "network",
			Severity:    SeverityWarn,
			Description: "Relay fallback",
			AllowedProperties: []AllowedProperty{
				{Name: "direct_error", Type: "string"},
			},
		},
		{
			Name:        "ssh.session.started",
			Version:     1,
			RecordType:  RecordTypeAnalytics,
			Feature:     "ssh",
			Severity:    SeverityInfo,
			Description: "SSH session started",
			AllowedProperties: []AllowedProperty{
				{Name: "session_type", Type: "string"},
				{Name: "auth_method", Type: "string"},
			},
		},
		{
			Name:        "ssh.session.terminated",
			Version:     1,
			RecordType:  RecordTypeAnalytics,
			Feature:     "ssh",
			Severity:    SeverityInfo,
			Description: "SSH session terminated",
			AllowedProperties: []AllowedProperty{
				{Name: "duration_ms", Type: "integer"},
				{Name: "exit_code", Type: "integer"},
			},
		},
		{
			Name:        "ssh.session.failed",
			Version:     1,
			RecordType:  RecordTypeDiagnostic,
			Feature:     "ssh",
			Severity:    SeverityError,
			Description: "SSH session failed",
			AllowedProperties: []AllowedProperty{
				{Name: "stage", Type: "string"},
				{Name: "retry_count", Type: "integer"},
			},
		},
		{
			Name:        "sftp.transfer.started",
			Version:     1,
			RecordType:  RecordTypeAnalytics,
			Feature:     "sftp",
			Severity:    SeverityInfo,
			Description: "SFTP transfer started",
			AllowedProperties: []AllowedProperty{
				{Name: "direction", Type: "string", Required: true},
				{Name: "file_size_bytes", Type: "integer"},
			},
		},
		{
			Name:        "sftp.transfer.completed",
			Version:     1,
			RecordType:  RecordTypeAnalytics,
			Feature:     "sftp",
			Severity:    SeverityInfo,
			Description: "SFTP transfer completed",
			AllowedProperties: []AllowedProperty{
				{Name: "direction", Type: "string", Required: true},
				{Name: "bytes_transferred", Type: "integer", Required: true},
				{Name: "duration_ms", Type: "integer"},
			},
		},
		{
			Name:        "sftp.transfer.failed",
			Version:     1,
			RecordType:  RecordTypeDiagnostic,
			Feature:     "sftp",
			Severity:    SeverityError,
			Description: "SFTP transfer failed",
			AllowedProperties: []AllowedProperty{
				{Name: "direction", Type: "string", Required: true},
				{Name: "bytes_transferred", Type: "integer"},
				{Name: "stage", Type: "string"},
			},
		},
		{
			Name:        "lan.discovery.peer_found",
			Version:     1,
			RecordType:  RecordTypeAnalytics,
			Feature:     "lan_share",
			Severity:    SeverityInfo,
			Description: "LAN peer found",
			AllowedProperties: []AllowedProperty{
				{Name: "peer_count", Type: "integer"},
			},
		},
		{
			Name:        "lan.transfer.completed",
			Version:     1,
			RecordType:  RecordTypeAnalytics,
			Feature:     "lan_share",
			Severity:    SeverityInfo,
			Description: "LAN transfer completed",
			AllowedProperties: []AllowedProperty{
				{Name: "bytes_transferred", Type: "integer", Required: true},
				{Name: "duration_ms", Type: "integer"},
			},
		},
		{
			Name:        "ai.chat.request",
			Version:     1,
			RecordType:  RecordTypeAnalytics,
			Feature:     "ai",
			Severity:    SeverityInfo,
			Description: "AI chat request",
			AllowedProperties: []AllowedProperty{
				{Name: "model_type", Type: "string"},
				{Name: "token_estimate", Type: "integer"},
			},
		},
		{
			Name:        "ai.chat.response",
			Version:     1,
			RecordType:  RecordTypeAnalytics,
			Feature:     "ai",
			Severity:    SeverityInfo,
			Description: "AI chat response",
			AllowedProperties: []AllowedProperty{
				{Name: "latency_ms", Type: "integer"},
				{Name: "status", Type: "string"},
			},
		},
		{
			Name:        "ai.chat.failed",
			Version:     1,
			RecordType:  RecordTypeDiagnostic,
			Feature:     "ai",
			Severity:    SeverityError,
			Description: "AI chat failed",
			AllowedProperties: []AllowedProperty{
				{Name: "provider", Type: "string"},
				{Name: "http_status", Type: "integer"},
			},
		},
		{
			Name:        "app.diagnostic.log",
			Version:     1,
			RecordType:  RecordTypeDiagnostic,
			Feature:     "app",
			Severity:    SeverityWarn,
			Description: "General diagnostic log",
			AllowedProperties: []AllowedProperty{
				{Name: "message", Type: "string"},
				{Name: "category", Type: "string"},
				{Name: "stage", Type: "string"},
				{Name: "direct_error", Type: "string"},
				{Name: "details", Type: "string"},
			},
		},
		{
			Name:        "telemetry.batch.uploaded",
			Version:     1,
			RecordType:  RecordTypeAnalytics,
			Feature:     "telemetry",
			Severity:    SeverityInfo,
			Description: "Telemetry uploaded",
			AllowedProperties: []AllowedProperty{
				{Name: "record_count", Type: "integer", Required: true},
				{Name: "duration_ms", Type: "integer"},
			},
		},
		{
			Name:        "telemetry.batch.failed",
			Version:     1,
			RecordType:  RecordTypeDiagnostic,
			Feature:     "telemetry",
			Severity:    SeverityWarn,
			Description: "Telemetry upload failed",
			AllowedProperties: []AllowedProperty{
				{Name: "error_type", Type: "string"},
				{Name: "http_status", Type: "integer"},
				{Name: "retry_count", Type: "integer"},
			},
		},
	}

	for _, ev := range events {
		c.events[ev.Name] = ev
	}

	// Error codes
	errors := []ErrorCodeDefinition{
		{Code: "NET_QUIC_CONN_REFUSED", Category: "network", TerminalFailure: false},
		{Code: "NET_QUIC_TIMEOUT", Category: "network", TerminalFailure: false},
		{Code: "NET_RELAY_UNAVAILABLE", Category: "network", TerminalFailure: true},
		{Code: "SSH_AUTH_FAILED", Category: "ssh", TerminalFailure: true},
		{Code: "SSH_HOST_KEY_MISMATCH", Category: "ssh", TerminalFailure: true},
		{Code: "SSH_TIMEOUT", Category: "ssh", TerminalFailure: true},
		{Code: "SFTP_PERMISSION_DENIED", Category: "sftp", TerminalFailure: true},
		{Code: "SFTP_FILE_NOT_FOUND", Category: "sftp", TerminalFailure: true},
		{Code: "SFTP_TRANSFER_ABORTED", Category: "sftp", TerminalFailure: true},
		{Code: "LAN_PEER_DISCONNECTED", Category: "lan", TerminalFailure: false},
		{Code: "LAN_HANDSHAKE_FAILED", Category: "lan", TerminalFailure: true},
		{Code: "AI_RATE_LIMITED", Category: "ai", TerminalFailure: false},
		{Code: "AI_SERVICE_UNAVAILABLE", Category: "ai", TerminalFailure: true},
		{Code: "TELEMETRY_AUTH_FAILED", Category: "telemetry", TerminalFailure: true},
		{Code: "TELEMETRY_NETWORK_ERROR", Category: "telemetry", TerminalFailure: false},
		{Code: "TELEMETRY_STORAGE_FULL", Category: "telemetry", TerminalFailure: false},
	}

	for _, ec := range errors {
		c.errorCodes[ec.Code] = ec
	}

	return c
}

// ValidateEnvelope performs full validation on an incoming TelemetryEnvelope.
func (c *Catalog) ValidateEnvelope(env *TelemetryEnvelope) error {
	if strings.TrimSpace(env.EventID) == "" {
		return fmt.Errorf("missing eventId")
	}
	if strings.TrimSpace(env.DeviceID) == "" {
		return fmt.Errorf("missing deviceId")
	}
	if strings.TrimSpace(env.SessionID) == "" {
		return fmt.Errorf("missing sessionId")
	}
	if strings.TrimSpace(env.TraceID) == "" {
		return fmt.Errorf("missing traceId")
	}
	if env.OccurredAt.IsZero() {
		return fmt.Errorf("missing or invalid occurredAt timestamp")
	}

	if err := c.ValidateEvent(env.EventName, env.EventVersion, env.Properties); err != nil {
		return err
	}

	if env.Error != nil {
		if err := c.ValidateErrorCode(env.Error.ErrorCode); err != nil {
			return err
		}
	}

	return nil
}
