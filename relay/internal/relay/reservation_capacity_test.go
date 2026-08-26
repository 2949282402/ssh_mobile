package relay

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestMemoryReservationCapacityIsBoundedAndReclaimed(t *testing.T) {
	store := newMemoryStore(Config{MaxTransferSessions: 2})
	ctx := context.Background()
	reservation := func(id string, expiry time.Time) Reservation {
		return Reservation{ReservationID: id, ExpiresAtMs: expiry.UnixMilli()}
	}
	now := time.Now()
	if err := store.CreateReservation(ctx, reservation("one", now.Add(time.Minute))); err != nil {
		t.Fatal(err)
	}
	if err := store.CreateReservation(ctx, reservation("two", now.Add(time.Minute))); err != nil {
		t.Fatal(err)
	}
	if err := store.CreateReservation(ctx, reservation("three", now.Add(time.Minute))); !errors.Is(err, errReservationCapacity) {
		t.Fatalf("third live reservation error = %v, want capacity", err)
	}
	if err := store.CreateReservation(ctx, reservation("one", now.Add(time.Minute))); !errors.Is(err, errReservationExists) {
		t.Fatalf("duplicate reservation error = %v, want exists", err)
	}
	if err := store.DeleteReservation(ctx, "one"); err != nil {
		t.Fatal(err)
	}
	if err := store.CreateReservation(ctx, reservation("three", now.Add(time.Minute))); err != nil {
		t.Fatalf("deleted slot was not reclaimed: %v", err)
	}

	store = newMemoryStore(Config{MaxTransferSessions: 1})
	store.reservations["expired"] = reservationEntry{
		reservation: reservation("expired", now.Add(-time.Minute)),
		expiresAt:   now.Add(-time.Second),
	}
	if err := store.CreateReservation(ctx, reservation("replacement", now.Add(time.Minute))); err != nil {
		t.Fatalf("expired slot was not reclaimed: %v", err)
	}
}

func TestMemoryReservationCapacityIsAtomicUnderConcurrency(t *testing.T) {
	const capacity = 4
	store := newMemoryStore(Config{MaxTransferSessions: capacity})
	ctx := context.Background()
	start := make(chan struct{})
	var successes atomic.Int32
	var wait sync.WaitGroup
	for i := 0; i < 32; i++ {
		wait.Add(1)
		go func(index int) {
			defer wait.Done()
			<-start
			err := store.CreateReservation(ctx, Reservation{
				ReservationID: fmt.Sprintf("concurrent-%d", index),
				ExpiresAtMs:   time.Now().Add(time.Minute).UnixMilli(),
			})
			if err == nil {
				successes.Add(1)
				return
			}
			if !errors.Is(err, errReservationCapacity) {
				t.Errorf("unexpected reservation error: %v", err)
			}
		}(i)
	}
	close(start)
	wait.Wait()
	if got := successes.Load(); got != capacity {
		t.Fatalf("successful reservations = %d, want %d", got, capacity)
	}
}

func TestRedisReservationCapacity(t *testing.T) {
	base, err := url.Parse(requireRedisURL(t))
	if err != nil {
		t.Fatal(err)
	}
	// Use a dedicated logical database so the global capacity indexes cannot
	// interfere with the other Redis integration tests in this package.
	base.Path = "/14"
	ctx := context.Background()
	store, err := openRedisStore(ctx, base.String(), Config{
		MaxTransferSessions: 2,
	})
	if err != nil {
		t.Fatalf("open isolated Redis store: %v", err)
	}
	defer store.Close()
	if err := store.client.FlushDB(ctx).Err(); err != nil {
		t.Fatal(err)
	}
	defer store.client.FlushDB(ctx)

	expiresAt := time.Now().Add(time.Minute).UnixMilli()
	for _, id := range []string{"one", "two"} {
		if err := store.CreateReservation(ctx, Reservation{ReservationID: id, ExpiresAtMs: expiresAt}); err != nil {
			t.Fatal(err)
		}
	}
	if err := store.CreateReservation(ctx, Reservation{ReservationID: "three", ExpiresAtMs: expiresAt}); !errors.Is(err, errReservationCapacity) {
		t.Fatalf("Redis third reservation error = %v, want capacity", err)
	}
	if err := store.DeleteReservation(ctx, "one"); err != nil {
		t.Fatal(err)
	}
	if err := store.CreateReservation(ctx, Reservation{ReservationID: "three", ExpiresAtMs: expiresAt}); err != nil {
		t.Fatalf("Redis reservation slot was not reclaimed: %v", err)
	}
}
