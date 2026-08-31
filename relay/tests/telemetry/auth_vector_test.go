package telemetry_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	. "github.com/ssh-mobile/relay/internal/telemetry"
)

type authVectorFile struct {
	MessagePattern string `json:"messagePattern"`
	KeyDerivation  string `json:"keyDerivation"`
	Vectors        []struct {
		Secret   string `json:"secret"`
		DeviceID string `json:"deviceId"`
		ExpEpoch int64  `json:"expEpoch"`
		Proof    string `json:"proof"`
	} `json:"vectors"`
}

func TestAuthProofGoldenVectors(t *testing.T) {
	// Find auth_proof_vectors.json relative to repository root or test location
	candidates := []string{
		"../../../contracts/telemetry/auth_proof_vectors.json",
		"../../contracts/telemetry/auth_proof_vectors.json",
		"contracts/telemetry/auth_proof_vectors.json",
	}

	var vectorData []byte
	var err error
	for _, p := range candidates {
		abs, absErr := filepath.Abs(p)
		if absErr == nil {
			if data, readErr := os.ReadFile(abs); readErr == nil {
				vectorData = data
				break
			}
		}
	}

	if vectorData == nil {
		t.Fatalf("could not load auth_proof_vectors.json from any candidate path: %v", err)
	}

	var vf authVectorFile
	if err := json.Unmarshal(vectorData, &vf); err != nil {
		t.Fatalf("unmarshal auth_proof_vectors.json: %v", err)
	}

	if len(vf.Vectors) == 0 {
		t.Fatal("expected at least one test vector in auth_proof_vectors.json")
	}

	for _, v := range vf.Vectors {
		t.Run("vector_"+v.DeviceID, func(t *testing.T) {
			storedHash := hashSecret(v.Secret)
			computedProof := deviceProof(v.DeviceID, storedHash, v.ExpEpoch)
			if computedProof != v.Proof {
				t.Fatalf("vector mismatch for device %s:\n  got:  %s\n  want: %s", v.DeviceID, computedProof, v.Proof)
			}

			// Verify that VerifyDeviceProof accepts the valid proof
			if !VerifyDeviceProof(v.DeviceID, storedHash, v.Proof, v.ExpEpoch) {
				t.Fatalf("VerifyDeviceProof returned false for golden vector device %s", v.DeviceID)
			}

			// Verify that tamper on deviceID fails
			if VerifyDeviceProof(v.DeviceID+"-tampered", storedHash, v.Proof, v.ExpEpoch) {
				t.Fatalf("VerifyDeviceProof accepted tampered deviceID")
			}

			// Verify that tamper on expEpoch fails
			if VerifyDeviceProof(v.DeviceID, storedHash, v.Proof, v.ExpEpoch+1) {
				t.Fatalf("VerifyDeviceProof accepted tampered expEpoch")
			}

			// Verify that tamper on proof fails
			tamperedProof := v.Proof[:len(v.Proof)-1] + "0"
			if tamperedProof == v.Proof {
				tamperedProof = v.Proof[:len(v.Proof)-1] + "1"
			}
			if VerifyDeviceProof(v.DeviceID, storedHash, tamperedProof, v.ExpEpoch) {
				t.Fatalf("VerifyDeviceProof accepted tampered proof")
			}
		})
	}
}
