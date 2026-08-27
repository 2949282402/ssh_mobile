package telemetry

import (
	"os"
	"path/filepath"
	"testing"
)

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
