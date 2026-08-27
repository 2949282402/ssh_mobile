package telemetry

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTelemetryArchitectureBoundaries(t *testing.T) {
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("failed to get working dir: %v", err)
	}

	relayInternalDir := filepath.Clean(filepath.Join(wd, ".."))

	forbiddenRelayImport := "github.com/ssh-mobile/relay" + "/internal/telemetry"
	forbiddenTelemetryImport := "github.com/ssh-mobile/relay" + "/internal/relay"

	// 1. Check that relay package does not import telemetry
	relayDir := filepath.Join(relayInternalDir, "relay")
	err = filepath.Walk(relayDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		content, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if strings.Contains(string(content), forbiddenRelayImport) {
			t.Errorf("boundary violation: %s imports internal/telemetry", path)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("failed walking relay dir: %v", err)
	}

	// 2. Check that telemetry package does not import internal/relay
	telemetryDir := filepath.Join(relayInternalDir, "telemetry")
	err = filepath.Walk(telemetryDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		content, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if strings.Contains(string(content), forbiddenTelemetryImport) {
			t.Errorf("boundary violation: %s imports internal/relay", path)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("failed walking telemetry dir: %v", err)
	}
}
