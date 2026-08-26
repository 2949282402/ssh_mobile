package relay

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestPackageImportIsolation enforces the architectural boundary:
// internal/relay must never import internal/admin.
func TestPackageImportIsolation(t *testing.T) {
	relayDir := "."
	entries, err := os.ReadDir(relayDir)
	if err != nil {
		t.Fatal(err)
	}

	forbiddenAdminImport := "github.com/ssh-mobile/relay" + "/internal/admin"

	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".go") || entry.Name() == "architecture_boundary_test.go" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(relayDir, entry.Name()))
		if err != nil {
			t.Fatal(err)
		}
		content := string(data)
		if strings.Contains(content, `"`+forbiddenAdminImport+`"`) {
			t.Fatalf("file %s violates architecture boundary: imports internal/admin", entry.Name())
		}
	}
}
