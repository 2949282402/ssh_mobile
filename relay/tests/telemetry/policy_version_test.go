package telemetry_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

func settingsWithPolicyVersion(version int) TelemetrySettings {
	settings := DefaultSettings()
	settings.Policy.PolicyVersion = version
	return settings
}

func TestPolicyVersionContractBounds(t *testing.T) {
	if MinPolicyVersion != 1 || MaxPolicyVersion != 2147483647 {
		t.Fatalf("Go policy bounds = %d..%d, want 1..2147483647", MinPolicyVersion, MaxPolicyVersion)
	}
	for _, version := range []int{MinPolicyVersion, MaxPolicyVersion} {
		if !IsValidPolicyVersion(version) {
			t.Fatalf("policy version %d should be valid", version)
		}
	}
	for _, version := range []int{0, MaxPolicyVersion + 1} {
		if IsValidPolicyVersion(version) {
			t.Fatalf("policy version %d should be invalid", version)
		}
		if !errors.Is(ValidatePolicyVersion(version), ErrInvalidPolicyVersion) {
			t.Fatalf("ValidatePolicyVersion(%d) did not return ErrInvalidPolicyVersion", version)
		}
	}

	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	policyPath := filepath.Join(filepath.Clean(filepath.Join(wd, "..", "..", "..")), "contracts", "telemetry", "policy.schema.json")
	data, err := os.ReadFile(policyPath)
	if err != nil {
		t.Fatalf("read policy schema: %v", err)
	}
	var schema struct {
		Properties map[string]struct {
			Minimum float64 `json:"minimum"`
			Maximum float64 `json:"maximum"`
		} `json:"properties"`
	}
	if err := json.Unmarshal(data, &schema); err != nil {
		t.Fatalf("decode policy schema: %v", err)
	}
	policyVersion := schema.Properties["policyVersion"]
	if policyVersion.Minimum != MinPolicyVersion || policyVersion.Maximum != MaxPolicyVersion {
		t.Fatalf("policy schema bounds = %v..%v, want %d..%d", policyVersion.Minimum, policyVersion.Maximum, MinPolicyVersion, MaxPolicyVersion)
	}
}

func TestMemoryStorePolicyVersionBoundariesAndNoClamping(t *testing.T) {
	ctx := context.Background()
	for _, version := range []int{MinPolicyVersion, MaxPolicyVersion} {
		store := NewMemoryStore(DefaultCatalog())
		if err := store.SaveSettings(ctx, settingsWithPolicyVersion(version)); err != nil {
			t.Fatalf("SaveSettings(%d) failed: %v", version, err)
		}
		got, err := store.GetSettings(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if got.Policy.PolicyVersion != version {
			t.Fatalf("persisted policy version = %d, want %d", got.Policy.PolicyVersion, version)
		}
	}

	for _, version := range []int{0, MaxPolicyVersion + 1} {
		store := NewMemoryStore(DefaultCatalog())
		initial := settingsWithPolicyVersion(MinPolicyVersion)
		initial.RetentionDays = 17
		if err := store.SaveSettings(ctx, initial); err != nil {
			t.Fatalf("seed settings: %v", err)
		}
		invalid := settingsWithPolicyVersion(version)
		invalid.RetentionDays = 99
		if err := store.SaveSettings(ctx, invalid); !errors.Is(err, ErrInvalidPolicyVersion) {
			t.Fatalf("SaveSettings(%d) error = %v, want ErrInvalidPolicyVersion", version, err)
		}
		got, err := store.GetSettings(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if got.Policy.PolicyVersion != MinPolicyVersion || got.RetentionDays != 17 {
			t.Fatalf("invalid version %d changed settings: %#v", version, got)
		}

		SanitizeSettings(&invalid)
		if invalid.Policy.PolicyVersion != version {
			t.Fatalf("SanitizeSettings clamped invalid version %d to %d", version, invalid.Policy.PolicyVersion)
		}
	}
}

func TestTelemetrySettingsRejectsInvalidPolicyVersionBeforePersistence(t *testing.T) {
	store := NewMemoryStore(DefaultCatalog())
	service := NewServiceWithSecret(store, DefaultCatalog(), &NoopRedisCache{}, "policy-version-auth-secret")
	handler := NewHandler(service)
	mux := http.NewServeMux()
	handler.RegisterAdminRoutes(mux, func(next http.HandlerFunc) http.HandlerFunc { return next })

	initial := settingsWithPolicyVersion(MinPolicyVersion)
	initial.RetentionDays = 23
	if err := store.SaveSettings(context.Background(), initial); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	staleBody, err := json.Marshal(initial)
	if err != nil {
		t.Fatal(err)
	}
	staleRequest := httptest.NewRequest(http.MethodPut, PathAdminSettings, bytes.NewReader(staleBody))
	staleRequest.Header.Set("Content-Type", "application/json")
	staleResponse := httptest.NewRecorder()
	mux.ServeHTTP(staleResponse, staleRequest)
	if staleResponse.Code != http.StatusConflict || !bytes.Contains(staleResponse.Body.Bytes(), []byte("POLICY_VERSION_CONFLICT")) {
		t.Fatalf("legal stale policy version status = %d, want 409 POLICY_VERSION_CONFLICT: %s", staleResponse.Code, staleResponse.Body.String())
	}

	for _, version := range []int{0, MaxPolicyVersion + 1} {
		invalid := initial
		invalid.Policy.PolicyVersion = version
		invalid.RetentionDays = 91
		body, err := json.Marshal(invalid)
		if err != nil {
			t.Fatal(err)
		}
		req := httptest.NewRequest(http.MethodPut, PathAdminSettings, bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("invalid policy version %d status = %d, want 400: %s", version, rec.Code, rec.Body.String())
		}
		var response struct {
			Error struct {
				Code string `json:"code"`
			} `json:"error"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
			t.Fatalf("decode invalid policy response: %v", err)
		}
		if response.Error.Code != "INVALID_REQUEST" {
			t.Fatalf("invalid policy version %d error code = %q, want INVALID_REQUEST", version, response.Error.Code)
		}
		persisted, err := store.GetSettings(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if persisted.Policy.PolicyVersion != MinPolicyVersion || persisted.RetentionDays != 23 {
			t.Fatalf("invalid policy version %d changed persisted settings: %#v", version, persisted)
		}
	}
}
