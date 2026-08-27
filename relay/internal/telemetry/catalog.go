// Event and error code catalog validation and registry.

package telemetry

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
)

//go:embed contracts/telemetry/events.json
var defaultEventsJSON []byte

//go:embed contracts/telemetry/error_codes.json
var defaultErrorCodesJSON []byte

// ContractPaths are the canonical contract source paths relative to the repo
// root. They are used by LoadContractCatalog for environments that ship the
// contracts directory (development and the repo CI) and by the stale-checker
// helpers that keep the embedded copies in sync.
const (
	ContractEventsPath = "contracts/telemetry/events.json"
	ContractErrorsPath = "contracts/telemetry/error_codes.json"
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

	return catalogFromJSON(eventsData, errorsData)
}

// LoadCatalogFromBytes parses catalog definitions from in-memory JSON bytes.
func LoadCatalogFromBytes(eventsJSON, errorsJSON []byte) (*Catalog, error) {
	var ep eventsPayload
	if err := json.Unmarshal(eventsJSON, &ep); err != nil {
		return nil, fmt.Errorf("unmarshal events JSON: %w", err)
	}
	var ecp errorCodesPayload
	if err := json.Unmarshal(errorsJSON, &ecp); err != nil {
		return nil, fmt.Errorf("unmarshal error codes JSON: %w", err)
	}
	return catalogFromPayloads(&ep, &ecp), nil
}

func catalogFromJSON(eventsJSON, errorsJSON []byte) (*Catalog, error) {
	var ep eventsPayload
	if err := json.Unmarshal(eventsJSON, &ep); err != nil {
		return nil, fmt.Errorf("unmarshal events JSON: %w", err)
	}
	var ecp errorCodesPayload
	if err := json.Unmarshal(errorsJSON, &ecp); err != nil {
		return nil, fmt.Errorf("unmarshal error codes JSON: %w", err)
	}
	return catalogFromPayloads(&ep, &ecp), nil
}

func catalogFromPayloads(ep *eventsPayload, ecp *errorCodesPayload) *Catalog {
	c := NewCatalog()
	for _, ev := range ep.Events {
		c.events[ev.Name] = ev
	}
	for _, ec := range ecp.ErrorCodes {
		c.errorCodes[ec.Code] = ec
	}
	return c
}

// DefaultCatalog returns the catalog bundled from contracts/telemetry at build
// time. It is used only as a fallback for package-local constructors; the Admin
// server wires a contract catalog explicitly.
func DefaultCatalog() *Catalog {
	c, err := catalogFromJSON(defaultEventsJSON, defaultErrorCodesJSON)
	if err != nil {
		// The embedded contract artifacts are validated by contract_test.go
		// before release; a parse failure here is a packaging defect.
		panic(fmt.Sprintf("embedded telemetry contract catalog is invalid: %v", err))
	}
	return c
}

// LoadContractCatalog loads the canonical catalog from the repository contracts
// directory. It is used by the Admin entry point at runtime.
func LoadContractCatalog(eventsPath, errorsPath string) (*Catalog, error) {
	return LoadCatalogFromFiles(eventsPath, errorsPath)
}

// DefaultCatalogMatchesContract reports whether the embedded catalog is
// byte-for-byte identical to the contract files at the given paths. It is used
// by tests and CI to detect contract drift.
func DefaultCatalogMatchesContract(eventsPath, errorsPath string) bool {
	eventsData, err := os.ReadFile(eventsPath)
	if err != nil {
		return false
	}
	errorsData, err := os.ReadFile(errorsPath)
	if err != nil {
		return false
	}
	return bytes.Equal(eventsData, defaultEventsJSON) && bytes.Equal(errorsData, defaultErrorCodesJSON)
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
