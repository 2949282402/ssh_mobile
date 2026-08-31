package telemetry_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestTelemetryContractGeneratedCatalogMatchesFiles(t *testing.T) {
	// The generated catalog must stay semantically in sync with the canonical
	// JSON artifacts emitted from YAML, so the Go backend never hardcodes a
	// divergent event/error set.
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("failed to get working dir: %v", err)
	}
	rootDir := filepath.Clean(filepath.Join(wd, "..", "..", ".."))
	eventsPath := filepath.Join(rootDir, "contracts", "telemetry", "events.json")
	errorsPath := filepath.Join(rootDir, "contracts", "telemetry", "error_codes.json")
	if !DefaultCatalogMatchesContract(eventsPath, errorsPath) {
		t.Fatalf("generated telemetry catalog drifted from contracts/telemetry; regenerate with dart run tool/gen_telemetry_contract.dart")
	}

	// Both loaders agree on the event/error sets.
	generated := DefaultCatalog()
	fileLoaded, err := LoadCatalogFromFiles(eventsPath, errorsPath)
	if err != nil {
		t.Fatalf("failed to load contract files: %v", err)
	}
	for _, name := range []string{"ssh.session.started", "telemetry.batch.uploaded"} {
		def, ok := generated.GetEvent(name)
		if !ok {
			t.Fatalf("generated catalog missing event %s", name)
		}
		fileDef, fileOK := fileLoaded.GetEvent(name)
		if !fileOK || def.Name != fileDef.Name || def.Version != fileDef.Version || def.Feature != fileDef.Feature || len(def.AllowedProperties) != len(fileDef.AllowedProperties) {
			t.Fatalf("event %s differs between generated and file catalog", name)
		}
	}
}

func TestTelemetryContractValidation(t *testing.T) {
	// Find root directory
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("failed to get working dir: %v", err)
	}
	// wd is expected to be relay/internal/telemetry or relay
	rootDir := filepath.Clean(filepath.Join(wd, "..", "..", ".."))
	eventsPath := filepath.Join(rootDir, "contracts", "telemetry", "events.json")
	errorsPath := filepath.Join(rootDir, "contracts", "telemetry", "error_codes.json")

	catalog, err := LoadCatalogFromFiles(eventsPath, errorsPath)
	if err != nil {
		t.Fatalf("failed to load catalog from files: %v", err)
	}

	t.Run("validates registered events", func(t *testing.T) {
		eventDef, ok := catalog.GetEvent("ssh.session.started")
		if !ok {
			t.Fatalf("expected event 'ssh.session.started' to be registered")
		}
		if eventDef.RecordType != RecordTypeAnalytics {
			t.Errorf("expected recordType analytics, got %s", eventDef.RecordType)
		}
		if eventDef.Feature != "ssh" {
			t.Errorf("expected feature ssh, got %s", eventDef.Feature)
		}
	})

	t.Run("rejects unregistered event name", func(t *testing.T) {
		err := catalog.ValidateEvent("unregistered.event.name", 1, map[string]any{"foo": "bar"})
		if err == nil {
			t.Fatalf("expected validation error for unregistered event")
		}
	})

	t.Run("validates allowed properties", func(t *testing.T) {
		err := catalog.ValidateEvent("sftp.transfer.completed", 1, map[string]any{
			"direction":         "download",
			"bytes_transferred": 1024,
			"duration_ms":       500,
		})
		if err != nil {
			t.Fatalf("unexpected validation error: %v", err)
		}
	})

	t.Run("rejects unregistered property", func(t *testing.T) {
		err := catalog.ValidateEvent("sftp.transfer.completed", 1, map[string]any{
			"direction":         "download",
			"bytes_transferred": 1024,
			"unregistered_prop": "sensitive_val",
		})
		if err == nil {
			t.Fatalf("expected validation error for unregistered property")
		}
	})

	t.Run("validates registered error codes", func(t *testing.T) {
		errDef, ok := catalog.GetErrorCode("SSH_AUTH_FAILED")
		if !ok {
			t.Fatalf("expected SSH_AUTH_FAILED to be registered")
		}
		if !errDef.TerminalFailure {
			t.Errorf("expected SSH_AUTH_FAILED to be terminalFailure=true")
		}
		if errDef.Category != "ssh" {
			t.Errorf("expected category ssh, got %s", errDef.Category)
		}
	})

	t.Run("rejects unregistered error code", func(t *testing.T) {
		err := catalog.ValidateErrorCode("RANDOM_CUSTOM_ERROR")
		if err == nil {
			t.Fatalf("expected error for unregistered error code")
		}
	})
}

func TestTelemetryEnvelopeRejectsContractMetadataMismatches(t *testing.T) {
	catalog := DefaultCatalog()
	base := func() TelemetryEnvelope {
		return TelemetryEnvelope{
			EventID:      "evt-strict",
			RecordType:   RecordTypeAnalytics,
			EventName:    "ssh.session.started",
			EventVersion: 1,
			DeviceID:     "dev-strict",
			SessionID:    "sess-strict",
			TraceID:      "trace-strict",
			OccurredAt:   time.Now().UTC(),
			Feature:      "ssh",
			Severity:     SeverityInfo,
			AppVersion:   "1.0.0",
			BuildNumber:  "1",
			Platform:     "linux",
			Properties:   map[string]any{"session_type": "interactive"},
		}
	}

	tests := []struct {
		name   string
		mutate func(*TelemetryEnvelope)
	}{
		{
			name: "record type",
			mutate: func(env *TelemetryEnvelope) {
				env.RecordType = RecordTypeDiagnostic
			},
		},
		{
			name: "feature",
			mutate: func(env *TelemetryEnvelope) {
				env.Feature = "network"
			},
		},
		{
			name: "severity",
			mutate: func(env *TelemetryEnvelope) {
				env.Severity = SeverityError
			},
		},
		{
			name: "version",
			mutate: func(env *TelemetryEnvelope) {
				env.EventVersion = 2
			},
		},
		{
			name: "error category",
			mutate: func(env *TelemetryEnvelope) {
				env.EventName = "ssh.session.failed"
				env.RecordType = RecordTypeDiagnostic
				env.Severity = SeverityError
				env.Properties = map[string]any{"stage": "connect"}
				env.Error = &TelemetryError{
					ErrorCode:       "SSH_AUTH_FAILED",
					Category:        "network",
					TerminalFailure: true,
				}
			},
		},
		{
			name: "error terminal failure",
			mutate: func(env *TelemetryEnvelope) {
				env.EventName = "ssh.session.failed"
				env.RecordType = RecordTypeDiagnostic
				env.Severity = SeverityError
				env.Properties = map[string]any{"stage": "connect"}
				env.Error = &TelemetryError{
					ErrorCode:       "SSH_AUTH_FAILED",
					Category:        "ssh",
					TerminalFailure: false,
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			env := base()
			tt.mutate(&env)
			if err := catalog.ValidateEnvelope(&env); err == nil {
				t.Fatalf("expected %s mismatch to be rejected", tt.name)
			}
		})
	}
}

func TestTelemetryStoreRejectsMetadataMismatchPerRecord(t *testing.T) {
	store := NewMemoryStore(DefaultCatalog())
	env := TelemetryEnvelope{
		EventID:      "evt-strict-store",
		RecordType:   RecordTypeDiagnostic,
		EventName:    "ssh.session.started",
		EventVersion: 1,
		DeviceID:     "dev-strict",
		SessionID:    "sess-strict",
		TraceID:      "trace-strict",
		OccurredAt:   time.Now().UTC(),
		Feature:      "ssh",
		Severity:     SeverityInfo,
		AppVersion:   "1.0.0",
		BuildNumber:  "1",
		Platform:     "linux",
		Properties:   map[string]any{"session_type": "interactive"},
	}
	results, err := store.IngestBatch(context.Background(), []TelemetryEnvelope{env})
	if err != nil {
		t.Fatalf("ingest should return per-record rejection, got error: %v", err)
	}
	if len(results) != 1 || results[0].Status != StatusRejected {
		t.Fatalf("expected one rejected result, got %+v", results)
	}
}
