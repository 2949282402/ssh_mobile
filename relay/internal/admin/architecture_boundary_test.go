package admin

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestPackageImportIsolation enforces the architectural boundary between
// internal/admin and internal/relay: neither package may import the other.
func TestPackageImportIsolation(t *testing.T) {
	adminDir := "."
	entries, err := os.ReadDir(adminDir)
	if err != nil {
		t.Fatal(err)
	}

	forbiddenRelayImport := "github.com/ssh-mobile/relay" + "/internal/relay"
	forbiddenV2Import := "github.com/ssh-mobile/relay" + "/internal/relay/v2"

	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".go") || entry.Name() == "architecture_boundary_test.go" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(adminDir, entry.Name()))
		if err != nil {
			t.Fatal(err)
		}
		content := string(data)
		if strings.Contains(content, `"`+forbiddenRelayImport+`"`) ||
			strings.Contains(content, `"`+forbiddenV2Import+`"`) {
			t.Fatalf("file %s violates architecture boundary: imports internal/relay", entry.Name())
		}
	}
}
