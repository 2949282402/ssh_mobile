// Event and error code catalog validation and registry.

package telemetry

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	contractgen "github.com/ssh-mobile/relay/internal/telemetry/generated"
)

// ContractPaths are the canonical contract source paths relative to the repo
// root. They are used by LoadContractCatalog for environments that ship the
// contracts directory (development and the repo CI) and by the stale-checker
// helpers that keep the embedded copies in sync.
const (
	ContractEventsPath = "contracts/telemetry/events.json"
	ContractErrorsPath = "contracts/telemetry/error_codes.json"
)

const (
	telemetryPropertyTypeString  = "string"
	telemetryPropertyTypeInteger = "integer"
	telemetryPropertyTypeBoolean = "boolean"
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
	OperationGroup    string            `json:"operationGroup"`
	OperationRole     string            `json:"operationRole"`
	BusinessOperation bool              `json:"businessOperation"`
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

// MaxTelemetryFutureSkew bounds how far a client event may lead the trusted
// server clock. A small allowance covers ordinary device clock drift while
// rejecting timestamps that would poison delivery-delay trends. Older offline
// events remain valid without an age limit.
const MaxTelemetryFutureSkew = 5 * time.Minute

// ErrOccurredAtTooFarInFuture identifies an envelope rejected before storage
// because its client timestamp exceeds MaxTelemetryFutureSkew.
var ErrOccurredAtTooFarInFuture = errors.New("telemetry occurredAt is too far in the future")

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
	if err := decodeStrictContractJSON(eventsJSON, &ep); err != nil {
		return nil, fmt.Errorf("unmarshal events JSON: %w", err)
	}
	var ecp errorCodesPayload
	if err := decodeStrictContractJSON(errorsJSON, &ecp); err != nil {
		return nil, fmt.Errorf("unmarshal error codes JSON: %w", err)
	}
	if err := validateContractPropertyTypes(&ep); err != nil {
		return nil, err
	}
	return catalogFromPayloads(&ep, &ecp), nil
}

func catalogFromJSON(eventsJSON, errorsJSON []byte) (*Catalog, error) {
	return LoadCatalogFromBytes(eventsJSON, errorsJSON)
}

func decodeStrictContractJSON(data []byte, dst any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dst); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return errors.New("multiple JSON values")
		}
		return err
	}
	return nil
}

func validateContractPropertyTypes(payload *eventsPayload) error {
	for _, event := range payload.Events {
		for _, property := range event.AllowedProperties {
			if !isSupportedTelemetryPropertyType(property.Type) {
				return fmt.Errorf("event %q property %q has unsupported primitive type %q", event.Name, property.Name, property.Type)
			}
		}
	}
	return nil
}

func isSupportedTelemetryPropertyType(propertyType string) bool {
	switch propertyType {
	case telemetryPropertyTypeString, telemetryPropertyTypeInteger, telemetryPropertyTypeBoolean:
		return true
	default:
		return false
	}
}

func isTelemetryPropertyValueType(propertyType string, value any) bool {
	switch propertyType {
	case telemetryPropertyTypeString:
		_, ok := value.(string)
		return ok
	case telemetryPropertyTypeBoolean:
		_, ok := value.(bool)
		return ok
	case telemetryPropertyTypeInteger:
		return isTelemetryInteger(value)
	default:
		return false
	}
}

func isTelemetryInteger(value any) bool {
	switch value := value.(type) {
	case int:
		return true
	case int8:
		return true
	case int16:
		return true
	case int32:
		return true
	case int64:
		return true
	case uint:
		return uint64(value) <= uint64(1<<63-1)
	case uint8:
		return true
	case uint16:
		return true
	case uint32:
		return true
	case uint64:
		return value <= uint64(1<<63-1)
	case json.Number:
		if _, err := value.Int64(); err == nil {
			return true
		}
		floatValue, err := strconv.ParseFloat(string(value), 64)
		return err == nil && isWholeTelemetryFloat(floatValue)
	case float32:
		return isWholeTelemetryFloat(float64(value))
	case float64:
		return isWholeTelemetryFloat(value)
	default:
		return false
	}
}

func isWholeTelemetryFloat(value float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0) &&
		math.Trunc(value) == value && value >= -9223372036854775808 && value < 9223372036854775808
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

// DefaultCatalog returns the catalog generated from the YAML source of truth. It
// is used only as a fallback for package-local constructors; the Admin server
// wires a contract catalog explicitly.
func DefaultCatalog() *Catalog {
	c := NewCatalog()
	for _, event := range contractgen.TelemetryEvents {
		properties := make([]AllowedProperty, len(event.AllowedProperties))
		for i, property := range event.AllowedProperties {
			properties[i] = AllowedProperty{
				Name:     property.Name,
				Type:     property.Type,
				Required: property.Required,
			}
		}
		c.events[event.Name] = EventDefinition{
			Name:              event.Name,
			Version:           event.Version,
			RecordType:        RecordType(event.RecordType),
			Feature:           event.Feature,
			Severity:          Severity(event.Severity),
			OperationGroup:    event.OperationGroup,
			OperationRole:     event.OperationRole,
			BusinessOperation: event.BusinessOperation,
			Description:       event.Description,
			AllowedProperties: properties,
		}
	}
	for _, errorCode := range contractgen.TelemetryErrorCodes {
		c.errorCodes[errorCode.Code] = ErrorCodeDefinition{
			Code:            errorCode.Code,
			Category:        errorCode.Category,
			TerminalFailure: errorCode.TerminalFailure,
			Description:     errorCode.Description,
		}
	}
	return c
}

// LoadContractCatalog loads the canonical catalog from the repository contracts
// directory. It is used by the Admin entry point at runtime.
func LoadContractCatalog(eventsPath, errorsPath string) (*Catalog, error) {
	return LoadCatalogFromFiles(eventsPath, errorsPath)
}

// DefaultCatalogMatchesContract reports whether the generated catalog is
// semantically identical to the generated JSON contract files at the given
// paths. It is used by tests and CI to detect cross-language drift.
func DefaultCatalogMatchesContract(eventsPath, errorsPath string) bool {
	fileCatalog, err := LoadCatalogFromFiles(eventsPath, errorsPath)
	if err != nil {
		return false
	}
	generatedCatalog := DefaultCatalog()
	generatedCatalog.mu.RLock()
	defer generatedCatalog.mu.RUnlock()
	fileCatalog.mu.RLock()
	defer fileCatalog.mu.RUnlock()
	return reflect.DeepEqual(generatedCatalog.events, fileCatalog.events) &&
		reflect.DeepEqual(generatedCatalog.errorCodes, fileCatalog.errorCodes)
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

// catalogEventDefinitions returns a stable snapshot for bounded aggregation
// query construction. The catalog is normally generated and small; sorting
// keeps SQL argument order deterministic for tests and query diagnostics.
func catalogEventDefinitions(c *Catalog) []EventDefinition {
	if c == nil {
		return nil
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	events := make([]EventDefinition, 0, len(c.events))
	for _, definition := range c.events {
		events = append(events, definition)
	}
	sort.Slice(events, func(i, j int) bool {
		return events[i].Name < events[j].Name
	})
	return events
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
		if !isSupportedTelemetryPropertyType(p.Type) {
			return fmt.Errorf("event %q property %q has unsupported primitive type %q", name, p.Name, p.Type)
		}
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
	for k, value := range properties {
		property, exists := allowed[k]
		if !exists {
			return fmt.Errorf("unregistered property %q for event %q", k, name)
		}
		if !isTelemetryPropertyValueType(property.Type, value) {
			return fmt.Errorf("property %q for event %q has invalid type %q", k, name, property.Type)
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
	return c.ValidateEnvelopeAt(env, time.Now().UTC())
}

// ValidateEnvelopeAt performs full validation using the supplied trusted
// server time. Storage paths pass their transaction timestamp here so tests
// and production validation share one deterministic clock reading.
func (c *Catalog) ValidateEnvelopeAt(env *TelemetryEnvelope, now time.Time) error {
	if env == nil {
		return fmt.Errorf("missing envelope")
	}
	*env = sanitizeEnvelopeForServer(*env)
	if strings.TrimSpace(env.EventID) == "" {
		return fmt.Errorf("missing eventId")
	}
	// MySQL stores event IDs as exact binary values in VARBINARY(64). Keep the
	// same byte-length contract in memory so case and trailing whitespace remain
	// distinct without allowing a value that the durable backend cannot store.
	if len([]byte(env.EventID)) > 64 {
		return fmt.Errorf("eventId exceeds maximum length of 64 bytes")
	}
	if strings.TrimSpace(env.DeviceID) == "" {
		return fmt.Errorf("missing deviceId")
	}
	// Relay device identities are bounded at 128 bytes by the bootstrap
	// contract and telemetry_events.device_id stores VARCHAR(128). Reject
	// oversized identities explicitly instead of failing inside the durable
	// store or silently truncating an identity.
	if len([]byte(env.DeviceID)) > 128 {
		return fmt.Errorf("deviceId exceeds maximum length of 128 bytes")
	}
	if strings.TrimSpace(env.SessionID) == "" {
		return fmt.Errorf("missing sessionId")
	}
	if len([]byte(env.SessionID)) > 128 {
		return fmt.Errorf("sessionId exceeds maximum length of 128 bytes")
	}
	if strings.TrimSpace(env.TraceID) == "" {
		return fmt.Errorf("missing traceId")
	}
	if len([]byte(env.TraceID)) > 128 {
		return fmt.Errorf("traceId exceeds maximum length of 128 bytes")
	}
	// telemetry_events.release_channel is VARCHAR(32); enforce the same byte
	// bound so overlong channel labels are rejected explicitly rather than
	// failing inside the durable store.
	if len([]byte(env.ReleaseChannel)) > 32 {
		return fmt.Errorf("releaseChannel exceeds maximum length of 32 bytes")
	}
	if env.OccurredAt.IsZero() {
		return fmt.Errorf("missing or invalid occurredAt timestamp")
	}
	if now.IsZero() {
		now = time.Now().UTC()
	}
	if env.OccurredAt.After(now.Add(MaxTelemetryFutureSkew)) {
		return fmt.Errorf("%w: occurredAt=%s serverNow=%s allowance=%s", ErrOccurredAtTooFarInFuture, env.OccurredAt.UTC().Format(time.RFC3339Nano), now.UTC().Format(time.RFC3339Nano), MaxTelemetryFutureSkew)
	}

	c.mu.RLock()
	eventDef, eventOK := c.events[env.EventName]
	c.mu.RUnlock()
	if !eventOK {
		return fmt.Errorf("unregistered event name: %q", env.EventName)
	}
	if env.EventVersion != eventDef.Version {
		return fmt.Errorf("event %q version mismatch: expected %d, got %d", env.EventName, eventDef.Version, env.EventVersion)
	}
	if env.RecordType != eventDef.RecordType {
		return fmt.Errorf("event %q recordType mismatch: expected %q, got %q", env.EventName, eventDef.RecordType, env.RecordType)
	}
	if env.Feature != eventDef.Feature {
		return fmt.Errorf("event %q feature mismatch: expected %q, got %q", env.EventName, eventDef.Feature, env.Feature)
	}
	if env.Severity != eventDef.Severity {
		return fmt.Errorf("event %q severity mismatch: expected %q, got %q", env.EventName, eventDef.Severity, env.Severity)
	}
	if err := c.ValidateEvent(env.EventName, env.EventVersion, env.Properties); err != nil {
		return err
	}

	if env.Error != nil {
		errorDef, ok := c.GetErrorCode(env.Error.ErrorCode)
		if !ok {
			return fmt.Errorf("unregistered error code: %q", env.Error.ErrorCode)
		}
		if env.Error.Category != errorDef.Category {
			return fmt.Errorf("error code %q category mismatch: expected %q, got %q", env.Error.ErrorCode, errorDef.Category, env.Error.Category)
		}
		if env.Error.TerminalFailure != errorDef.TerminalFailure {
			return fmt.Errorf("error code %q terminalFailure mismatch: expected %t, got %t", env.Error.ErrorCode, errorDef.TerminalFailure, env.Error.TerminalFailure)
		}
	}

	return nil
}
