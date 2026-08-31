package telemetry_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestCatalogLoadersReportMalformedAndMissingContracts(t *testing.T) {
	if _, err := LoadCatalogFromFiles(filepath.Join(t.TempDir(), "missing-events.json"), "missing-errors.json"); err == nil || !strings.Contains(err.Error(), "read events file") {
		t.Fatalf("missing events file error = %v, want read error", err)
	}
	if _, err := LoadCatalogFromBytes([]byte("{"), []byte("{}")); err == nil || !strings.Contains(err.Error(), "unmarshal events JSON") {
		t.Fatalf("malformed events bytes error = %v, want unmarshal error", err)
	}
	if _, err := LoadCatalogFromBytes([]byte("{}"), []byte("{")); err == nil || !strings.Contains(err.Error(), "unmarshal error codes JSON") {
		t.Fatalf("malformed error bytes error = %v, want unmarshal error", err)
	}

	dir := t.TempDir()
	eventsPath := filepath.Join(dir, "events.json")
	errorsPath := filepath.Join(dir, "errors.json")
	if err := os.WriteFile(eventsPath, []byte(`{"version":"test","events":[]}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(errorsPath, []byte(`{"version":"test","errorCodes":[]}`), 0600); err != nil {
		t.Fatal(err)
	}
	loaded, err := LoadContractCatalog(eventsPath, errorsPath)
	if err != nil || loaded == nil {
		t.Fatalf("LoadContractCatalog = %#v, err=%v", loaded, err)
	}
	if DefaultCatalogMatchesContract(filepath.Join(dir, "no-events"), errorsPath) {
		t.Fatal("catalog matched a missing contract")
	}
}

func TestCatalogRegistrationAndValidationBoundaries(t *testing.T) {
	catalog := NewCatalog()
	catalog.RegisterEvent(EventDefinition{
		Name:       "required.event",
		Version:    2,
		RecordType: RecordTypeAnalytics,
		Feature:    "test",
		Severity:   SeverityInfo,
		AllowedProperties: []AllowedProperty{{
			Name: "required", Type: "string", Required: true,
		}},
	})
	catalog.RegisterErrorCode(ErrorCodeDefinition{Code: "TEST_ERROR", Category: "test"})
	if _, ok := catalog.GetEvent("required.event"); !ok {
		t.Fatal("registered event was not returned")
	}
	if _, ok := catalog.GetErrorCode("TEST_ERROR"); !ok {
		t.Fatal("registered error code was not returned")
	}
	if err := catalog.ValidateEvent("required.event", 1, nil); err == nil || !strings.Contains(err.Error(), "version mismatch") {
		t.Fatalf("event version error = %v, want version mismatch", err)
	}
	if err := catalog.ValidateEvent("required.event", 2, nil); err == nil || !strings.Contains(err.Error(), "missing required property") {
		t.Fatalf("required property error = %v, want missing-property error", err)
	}
	if err := catalog.ValidateEvent("required.event", 2, map[string]any{"required": "ok", "extra": true}); err == nil || !strings.Contains(err.Error(), "unregistered property") {
		t.Fatalf("unregistered property error = %v, want property error", err)
	}
	if err := catalog.ValidateEvent("required.event", 2, map[string]any{"required": "ok"}); err != nil {
		t.Fatalf("valid custom event: %v", err)
	}
	if err := catalog.ValidateErrorCode("UNKNOWN"); err == nil {
		t.Fatal("unknown error code unexpectedly validated")
	}
}

func TestCatalogRejectsInvalidEnvelopeBoundaries(t *testing.T) {
	catalog := DefaultCatalog()
	base := func() TelemetryEnvelope {
		return TelemetryEnvelope{
			EventID: "catalog-boundary", RecordType: RecordTypeAnalytics, EventName: "ssh.session.started",
			EventVersion: 1, DeviceID: "device", SessionID: "session", TraceID: "trace",
			OccurredAt: time.Date(2026, time.August, 28, 4, 0, 0, 0, time.UTC), Feature: "ssh",
			Severity: SeverityInfo, AppVersion: "1", BuildNumber: "1", Platform: "linux",
		}
	}
	tests := []struct {
		name   string
		mutate func(*TelemetryEnvelope)
		want   string
	}{
		{name: "nil envelope", mutate: nil, want: "missing envelope"},
		{name: "event id", mutate: func(env *TelemetryEnvelope) { env.EventID = "  " }, want: "missing eventId"},
		{name: "event id bytes", mutate: func(env *TelemetryEnvelope) { env.EventID = strings.Repeat("é", 33) }, want: "maximum length"},
		{name: "device id", mutate: func(env *TelemetryEnvelope) { env.DeviceID = " " }, want: "missing deviceId"},
		{name: "device id bytes", mutate: func(env *TelemetryEnvelope) { env.DeviceID = strings.Repeat("d", 129) }, want: "maximum length"},
		{name: "session id", mutate: func(env *TelemetryEnvelope) { env.SessionID = "" }, want: "missing sessionId"},
		{name: "session id bytes", mutate: func(env *TelemetryEnvelope) { env.SessionID = strings.Repeat("s", 129) }, want: "maximum length"},
		{name: "trace id", mutate: func(env *TelemetryEnvelope) { env.TraceID = "" }, want: "missing traceId"},
		{name: "trace id bytes", mutate: func(env *TelemetryEnvelope) { env.TraceID = strings.Repeat("t", 129) }, want: "maximum length"},
		{name: "release channel bytes", mutate: func(env *TelemetryEnvelope) { env.ReleaseChannel = strings.Repeat("c", 33) }, want: "maximum length"},
		{name: "occurred at", mutate: func(env *TelemetryEnvelope) { env.OccurredAt = time.Time{} }, want: "occurredAt"},
		{name: "event name", mutate: func(env *TelemetryEnvelope) { env.EventName = "unknown.event" }, want: "unregistered event name"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var err error
			if tc.mutate == nil {
				err = catalog.ValidateEnvelopeAt(nil, time.Time{})
			} else {
				env := base()
				tc.mutate(&env)
				err = catalog.ValidateEnvelopeAt(&env, time.Time{})
			}
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("validation error = %v, want %q", err, tc.want)
			}
		})
	}
}
