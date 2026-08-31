package telemetry

import "testing"

func TestTruncateDiagnosticTextBoundaries(t *testing.T) {
	tests := []struct {
		name     string
		value    string
		maxBytes int
		want     string
	}{
		{name: "empty", value: "", maxBytes: MaxDiagnosticTextLength, want: ""},
		{name: "fits exactly", value: "abc", maxBytes: 3, want: "abc"},
		{name: "truncates ascii", value: "abcdef", maxBytes: 3, want: "abc"},
		{name: "keeps whole multibyte rune", value: "\u754c\u754c\u754c", maxBytes: 4, want: "\u754c"},
		{name: "single oversized rune", value: "\u754c", maxBytes: 2, want: ""},
		{name: "long multibyte tail", value: "a\u754c\u754c", maxBytes: 4, want: "a\u754c"},
		{name: "zero cap", value: "abc", maxBytes: 0, want: ""},
		{name: "negative cap", value: "abc", maxBytes: -1, want: ""},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := truncateDiagnosticText(tc.value, tc.maxBytes); got != tc.want {
				t.Fatalf("truncateDiagnosticText(%q, %d) = %q, want %q", tc.value, tc.maxBytes, got, tc.want)
			}
		})
	}
}
