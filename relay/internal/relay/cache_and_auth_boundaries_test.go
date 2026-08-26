package relay

import (
	"context"
	"testing"
	"time"
)

func TestMemoryStoreGetDiscoveriesFiltersMissingAndExpired(t *testing.T) {
	store := newMemoryStore(Config{})
	store.mu.Lock()
	store.discovery["live"] = discoveryEntry{
		discovery: Discovery{DeviceID: "live", ConnectionID: "conn-live", Revision: 1},
		expiresAt: time.Now().Add(time.Minute),
	}
	store.discovery["expired"] = discoveryEntry{
		discovery: Discovery{DeviceID: "expired", ConnectionID: "conn-old", Revision: 1},
		expiresAt: time.Now().Add(-time.Second),
	}
	store.mu.Unlock()

	got, err := store.GetDiscoveries(context.Background(), []string{"live", "expired", "missing"})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got["live"].ConnectionID != "conn-live" {
		t.Fatalf("batch discovery result = %+v, want only live entry", got)
	}
	if _, present := store.discovery["expired"]; present {
		t.Fatal("expired discovery was not lazily removed")
	}
	empty, err := store.GetDiscoveries(context.Background(), nil)
	if err != nil || empty == nil || len(empty) != 0 {
		t.Fatalf("empty discovery batch = %+v, err=%v", empty, err)
	}
}

func TestMemoryCacheLeaseAndReservationBoundaries(t *testing.T) {
	ctx := context.Background()
	store := newMemoryStore(Config{})

	if _, present, err := store.GetPresence(ctx, "missing"); err != nil || present {
		t.Fatalf("missing presence = present=%v err=%v", present, err)
	}
	if _, _, err := store.TakePresence(ctx, "device", "owner", Presence{}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if renewed, err := store.RenewPresence(ctx, "device", "foreign", Presence{}, time.Minute); err != nil || renewed {
		t.Fatalf("foreign presence renewal = %v, err=%v", renewed, err)
	}
	if renewed, err := store.RenewPresence(ctx, "device", "owner", Presence{}, time.Minute); err != nil || !renewed {
		t.Fatalf("owner presence renewal = %v, err=%v", renewed, err)
	}
	if released, err := store.ReleasePresence(ctx, "device", "foreign"); err != nil || released {
		t.Fatalf("foreign presence release = %v, err=%v", released, err)
	}
	if released, err := store.ReleasePresence(ctx, "device", "owner"); err != nil || !released {
		t.Fatalf("owner presence release = %v, err=%v", released, err)
	}
	if released, err := store.ReleasePresence(ctx, "device", "owner"); err != nil || released {
		t.Fatalf("missing presence release = %v, err=%v", released, err)
	}

	if renewed, err := store.RenewDiscovery(ctx, "missing", "owner", time.Minute); err != nil || !renewed {
		t.Fatalf("missing discovery renewal = %v, err=%v", renewed, err)
	}
	if _, _, err := store.TakePresence(ctx, "device", "owner", Presence{}, time.Minute); err != nil {
		t.Fatal(err)
	}
	discovery := Discovery{DeviceID: "device", ConnectionID: "owner", Revision: 1, RuntimeEpochLow: 1}
	if err := store.TakeDiscovery(ctx, "device", "foreign", discovery, time.Minute); err != errDiscoveryNotOwner {
		t.Fatalf("foreign discovery take = %v, want ownership error", err)
	}
	if err := store.TakeDiscovery(ctx, "device", "owner", discovery, time.Minute); err != nil {
		t.Fatal(err)
	}
	if renewed, err := store.RenewDiscovery(ctx, "device", "foreign", time.Minute); err != nil || renewed {
		t.Fatalf("foreign discovery renewal = %v, err=%v", renewed, err)
	}
	if renewed, err := store.RenewDiscovery(ctx, "device", "owner", time.Minute); err != nil || !renewed {
		t.Fatalf("owner discovery renewal = %v, err=%v", renewed, err)
	}
	if released, err := store.ReleaseDiscovery(ctx, "device", "foreign"); err != nil || released {
		t.Fatalf("foreign discovery release = %v, err=%v", released, err)
	}
	if released, err := store.ReleaseDiscovery(ctx, "device", "owner"); err != nil || !released {
		t.Fatalf("owner discovery release = %v, err=%v", released, err)
	}
	if _, present, err := store.GetDiscovery(ctx, "device"); err != nil || present {
		t.Fatalf("released discovery = present=%v err=%v", present, err)
	}

	if err := store.CreateReservation(ctx, Reservation{}); err == nil {
		t.Fatal("empty reservation id was accepted")
	}
	reservation := Reservation{ReservationID: "reservation-boundary", ExpiresAtMs: time.Now().Add(time.Minute).UnixMilli()}
	if err := store.CreateReservation(ctx, reservation); err != nil {
		t.Fatal(err)
	}
	if got, present, err := store.GetReservation(ctx, reservation.ReservationID); err != nil || !present || got.ReservationID != reservation.ReservationID {
		t.Fatalf("reservation read = %+v present=%v err=%v", got, present, err)
	}
	if renewed, err := store.RenewReservation(ctx, reservation.ReservationID, time.Minute); err != nil || !renewed {
		t.Fatalf("reservation renewal = %v, err=%v", renewed, err)
	}
	if released := store.DeleteReservation(ctx, reservation.ReservationID); released != nil {
		t.Fatalf("reservation delete = %v", released)
	}
}
