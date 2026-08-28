package telemetry_test

import (
	"strings"
	"testing"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func TestIngestConfigFromEnvironmentRejectsInvalidValues(t *testing.T) {
	variables := []string{
		"TELEMETRY_MAX_BODY_BYTES", "TELEMETRY_MAX_BATCH_SIZE", "TELEMETRY_MAX_CONCURRENT_WRITERS",
		"TELEMETRY_RATE_LIMIT_CAPACITY", "TELEMETRY_RATE_LIMIT_REFILL_PER_SECOND", "TELEMETRY_RATE_LIMIT_MAX_DEVICES",
		"TELEMETRY_RATE_LIMIT_DEVICE_TTL", "TELEMETRY_RETRY_AFTER_SECONDS",
	}
	for _, tc := range []struct {
		name  string
		value string
		want  string
	}{
		{name: "zero integer", value: "0", want: "positive integer"},
		{name: "invalid integer", value: "not-an-integer", want: "positive integer"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for _, variable := range variables {
				t.Setenv(variable, "")
			}
			t.Setenv("TELEMETRY_MAX_BATCH_SIZE", tc.value)
			if _, err := IngestConfigFromEnvironment(); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("invalid integer error = %v, want %q", err, tc.want)
			}
		})
	}
	for _, tc := range []struct {
		name  string
		value string
		want  string
	}{
		{name: "zero float", value: "0", want: "positive number"},
		{name: "invalid float", value: "not-a-number", want: "positive number"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for _, variable := range variables {
				t.Setenv(variable, "")
			}
			t.Setenv("TELEMETRY_RATE_LIMIT_REFILL_PER_SECOND", tc.value)
			if _, err := IngestConfigFromEnvironment(); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("invalid float error = %v, want %q", err, tc.want)
			}
		})
	}
	for _, tc := range []struct {
		name  string
		value string
		want  string
	}{
		{name: "zero duration", value: "0s", want: "positive duration"},
		{name: "invalid duration", value: "not-a-duration", want: "positive duration"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for _, variable := range variables {
				t.Setenv(variable, "")
			}
			t.Setenv("TELEMETRY_RATE_LIMIT_DEVICE_TTL", tc.value)
			if _, err := IngestConfigFromEnvironment(); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("invalid duration error = %v, want %q", err, tc.want)
			}
		})
	}
}

func TestDefaultConfigFallsBackWhenEnvironmentIsInvalid(t *testing.T) {
	t.Setenv("TELEMETRY_MAX_BODY_BYTES", "not-an-integer")
	config := DefaultConfig()
	if config.MaxBodyBytes != MaxRequestBodyBytes || config.Ingest.MaxBodyBytes != MaxRequestBodyBytes {
		t.Fatalf("invalid environment DefaultConfig = %+v, want safe body limit", config)
	}
}
