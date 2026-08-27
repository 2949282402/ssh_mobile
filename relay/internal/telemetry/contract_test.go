package telemetry

import (
	"os"
	"path/filepath"
	"testing"
)

func TestEmbeddedCatalogMatchesContractFiles(t *testing.T) {
	// The embedded catalog must stay byte-for-byte in sync with the canonical
	// contracts so the Go backend never hardcodes a divergent event/error set.
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("failed to get working dir: %v", err)
	}
	rootDir := filepath.Clean(filepath.Join(wd, "..", "..", ".."))
	eventsPath := filepath.Join(rootDir, "contracts", "telemetry", "events.json")
	errorsPath := filepath.Join(rootDir, "contracts", "telemetry", "error_codes.json")
	if !DefaultCatalogMatchesContract(eventsPath, errorsPath) {
		t.Fatalf("embedded telemetry catalog drifted from contracts/telemetry; regenerate relay/internal/telemetry/contracts")
	}

	// Both loaders agree on the event/error sets.
	embedded := DefaultCatalog()
	fileLoaded, err := LoadCatalogFromFiles(eventsPath, errorsPath)
	if err != nil {
		t.Fatalf("failed to load contract files: %v", err)
	}
	for _, name := range []string{"ssh.session.started", "telemetry.batch.uploaded"} {
		def, ok := embedded.GetEvent(name)
		if !ok {
			t.Fatalf("embedded catalog missing event %s", name)
		}
		fileDef, fileOK := fileLoaded.GetEvent(name)
		if !fileOK || def.Name != fileDef.Name || def.Version != fileDef.Version || def.Feature != fileDef.Feature || len(def.AllowedProperties) != len(fileDef.AllowedProperties) {
			t.Fatalf("event %s differs between embedded and file catalog", name)
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
