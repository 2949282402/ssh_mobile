package relay

import (
	"context"
	"testing"
	"time"
)

func TestRelayDataReenrollInvalidatesPreUpgradeLease(t *testing.T) {
	server := NewServer(Config{})
	defer server.Close()
	if result := server.replaceEnrollment("device-a", "same-key", "test", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("initial enrollment result=%v", result)
	}
	lease, status := server.relayData.beginUpgrade("device-a")
	if status != relayDataUpgradeAccepted {
		t.Fatalf("begin upgrade status=%v", status)
	}
	if result := server.replaceEnrollment("device-a", "same-key", "test", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("re-enrollment result=%v", result)
	}
	if server.relayData.startEndpoint(lease, testRelayDataConnForRegistry("late-reenroll", "device-a", relayDataRoleInitiator)) {
		t.Fatal("re-enrollment must prevent a pre-101 RelayData request from registering late")
	}
}

func TestRelayDataLifecycleEventsInvalidatePreUpgradeLeases(t *testing.T) {
	for _, eventType := range []string{eventDeviceRevoked, eventDeviceKicked} {
		t.Run(eventType, func(t *testing.T) {
			server := NewServer(Config{})
			defer server.Close()
			lease, status := server.relayData.beginUpgrade("device-a")
			if status != relayDataUpgradeAccepted {
				t.Fatalf("begin upgrade status=%v", status)
			}
			server.handleRelayEvent(RelayEvent{Type: eventType, DeviceID: "device-a"})
			if server.relayData.startEndpoint(lease, testRelayDataConnForRegistry("late-event", "device-a", relayDataRoleInitiator)) {
				t.Fatalf("%s must prevent late RelayData registration", eventType)
			}
		})
	}
}

func TestDelayedKickPreservesCurrentEnrollmentGeneration(t *testing.T) {
	server := NewServer(Config{})
	defer server.Close()
	fixedTime := time.Now()
	if result := server.replaceEnrollment("device-a", "same-key", "test", 1, fixedTime); result != enrollmentOK {
		t.Fatalf("initial enrollment=%v", result)
	}
	oldGeneration := mustEnrollmentGeneration(t, server, "device-a")
	if result := server.replaceEnrollment("device-a", "same-key", "test", 1, fixedTime); result != enrollmentOK {
		t.Fatalf("re-enrollment=%v", result)
	}
	currentGeneration := mustEnrollmentGeneration(t, server, "device-a")

	currentPeer := injectPeer(server.hub, "device-a")
	currentPeer.enrollmentGeneration = currentGeneration
	lease, status := server.relayData.beginUpgrade("device-a", currentGeneration)
	if status != relayDataUpgradeAccepted {
		t.Fatalf("begin current-generation upgrade=%v", status)
	}
	server.handleRelayEvent(RelayEvent{
		Type:                 eventDeviceKicked,
		DeviceID:             "device-a",
		EnrollmentGeneration: oldGeneration,
	})

	server.hub.mutex.Lock()
	retainedPeer := server.hub.peers["device-a"]
	server.hub.mutex.Unlock()
	if retainedPeer != currentPeer {
		t.Fatal("delayed kick closed the current-generation control connection")
	}
	if !lease.active {
		t.Fatal("delayed kick invalidated the current-generation data upgrade")
	}
	lease.release()

	oldPeer := currentPeer
	oldPeer.enrollmentGeneration = oldGeneration
	server.handleRelayEvent(RelayEvent{
		Type:                 eventDeviceKicked,
		DeviceID:             "device-a",
		EnrollmentGeneration: oldGeneration,
	})
	select {
	case <-oldPeer.done:
	default:
		t.Fatal("kick did not close a connection older than the durable enrollment")
	}
}

func TestDelayedRevokePreservesLaterReenrollment(t *testing.T) {
	server := NewServer(Config{})
	defer server.Close()
	fixedTime := time.Now()
	if result := server.replaceEnrollment("device-a", "same-key", "test", 1, fixedTime); result != enrollmentOK {
		t.Fatalf("initial enrollment=%v", result)
	}
	outcome, revokedGeneration, err := server.store.RevokeEnrollment(context.Background(), "device-a", time.Hour)
	if err != nil || outcome != revokeOK {
		t.Fatalf("revoke: outcome=%v err=%v", outcome, err)
	}
	if result := server.replaceEnrollment("device-a", "same-key", "test", 1, fixedTime); result != enrollmentOK {
		t.Fatalf("re-enrollment=%v", result)
	}
	currentGeneration := mustEnrollmentGeneration(t, server, "device-a")
	if currentGeneration <= revokedGeneration {
		t.Fatalf("re-enrollment generation=%d, revoked=%d", currentGeneration, revokedGeneration)
	}
	currentPeer := injectPeer(server.hub, "device-a")
	currentPeer.enrollmentGeneration = currentGeneration

	server.handleRelayEvent(RelayEvent{
		Type:                 eventDeviceRevoked,
		DeviceID:             "device-a",
		EnrollmentGeneration: revokedGeneration,
	})
	server.hub.mutex.Lock()
	retainedPeer := server.hub.peers["device-a"]
	server.hub.mutex.Unlock()
	if retainedPeer != currentPeer {
		t.Fatal("delayed revoke closed the later re-enrollment")
	}
}

func TestRelayDataReconciliationIncludesDataOnlyDevices(t *testing.T) {
	server := NewServer(Config{})
	defer server.Close()
	if result := server.replaceEnrollment("device-data-only", "key", "test", 1, time.Now()); result != enrollmentOK {
		t.Fatalf("seed enrollment: result=%v", result)
	}
	lease, status := server.relayData.beginUpgrade("device-data-only", mustEnrollmentGeneration(t, server, "device-data-only"))
	if status != relayDataUpgradeAccepted {
		t.Fatalf("begin upgrade status=%v", status)
	}
	outcome, _, err := server.store.RevokeEnrollment(context.Background(), "device-data-only", time.Hour)
	if err != nil || outcome != revokeOK {
		t.Fatalf("record revocation: outcome=%v err=%v", outcome, err)
	}

	server.reconcileRevocationsOnce()
	if server.relayData.startEndpoint(lease, testRelayDataConnForRegistry("late-reconcile", "device-data-only", relayDataRoleInitiator)) {
		t.Fatal("data-only reconciliation must invalidate a revoked pre-101 request")
	}
}
