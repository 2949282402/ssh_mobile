package relay

import (
	"context"
	"crypto/tls"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
	"time"
)

func TestAdminAuthAddressAndRequestBoundaries(t *testing.T) {
	addressCases := []struct {
		name  string
		value string
		want  string
		ok    bool
	}{
		{name: "host and port", value: "198.51.100.8:443", want: "198.51.100.8", ok: true},
		{name: "bare ipv4", value: "198.51.100.9", want: "198.51.100.9", ok: true},
		{name: "bracketed ipv6", value: "[2001:db8::8]:443", want: "2001:db8::8", ok: true},
		{name: "bare ipv6", value: "2001:db8::9", want: "2001:db8::9", ok: true},
		{name: "malformed", value: "not-an-address", ok: false},
	}
	for _, tc := range addressCases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := remoteIP(tc.value)
			if ok != tc.ok || (ok && got.String() != tc.want) {
				t.Fatalf("remoteIP(%q) = (%s, %v), want (%s, %v)", tc.value, got, ok, tc.want, tc.ok)
			}
		})
	}

	server := NewServer(Config{
		TrustedProxyCIDRs: []netip.Prefix{netip.MustParsePrefix("192.0.2.0/24")},
	})
	defer server.Close()
	request := httptest.NewRequest(http.MethodGet, "http://relay.example/", nil)
	request.RemoteAddr = "192.0.2.10:443"
	request.Header.Set("X-Forwarded-For", "198.51.100.1, 192.0.2.11")
	if got := server.requestClientIP(request); got != "198.51.100.1" {
		t.Fatalf("trusted proxy client IP = %q, want rightmost untrusted address", got)
	}
	request.Header.Set("X-Forwarded-For", "192.0.2.11")
	request.Header.Set("X-Real-IP", "198.51.100.2")
	if got := server.requestClientIP(request); got != "198.51.100.2" {
		t.Fatalf("trusted proxy X-Real-IP fallback = %q, want 198.51.100.2", got)
	}
	request.Header.Set("X-Real-IP", "not-an-ip")
	if got := server.requestClientIP(request); got != "192.0.2.10" {
		t.Fatalf("invalid forwarded addresses should fall back to peer, got %q", got)
	}
	request.RemoteAddr = "invalid"
	if got := server.requestClientIP(request); got != "unknown" {
		t.Fatalf("invalid peer address = %q, want unknown", got)
	}

	originCases := []struct {
		name       string
		fetchSite  string
		origin     string
		tls        bool
		forwarded  string
		wantOrigin bool
	}{
		{name: "no metadata", wantOrigin: true},
		{name: "same origin", fetchSite: "same-origin", origin: "http://relay.example", wantOrigin: true},
		{name: "same site", fetchSite: "same-site", wantOrigin: true},
		{name: "cross site", fetchSite: "cross-site", wantOrigin: false},
		{name: "different host", origin: "http://other.example", wantOrigin: false},
		{name: "path is forbidden", origin: "http://relay.example/admin", wantOrigin: false},
		{name: "user info is forbidden", origin: "http://user@relay.example", wantOrigin: false},
		{name: "malformed origin", origin: "://", wantOrigin: false},
		{name: "forwarded tls", origin: "https://relay.example", forwarded: "https", wantOrigin: true},
		{name: "request tls", origin: "https://relay.example", tls: true, wantOrigin: true},
	}
	for _, tc := range originCases {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, "http://relay.example/admin", nil)
			r.Header.Set("Sec-Fetch-Site", tc.fetchSite)
			if tc.origin != "" {
				r.Header.Set("Origin", tc.origin)
			}
			if tc.forwarded != "" {
				r.Header.Set("X-Forwarded-Proto", tc.forwarded)
			}
			if tc.tls {
				r.TLS = &tls.ConnectionState{}
			}
			if got := adminRequestIsSameOrigin(r); got != tc.wantOrigin {
				t.Fatalf("same-origin result = %v, want %v", got, tc.wantOrigin)
			}
		})
	}

	bodyCases := []struct {
		name        string
		contentType string
		length      int64
		want        bool
	}{
		{name: "empty body", want: true},
		{name: "json", contentType: "application/json", length: 1, want: true},
		{name: "json with charset", contentType: "application/json; charset=utf-8", length: 1, want: true},
		{name: "text body", contentType: "text/plain", length: 1, want: false},
		{name: "malformed media type", contentType: "application/json; =bad", length: 1, want: false},
	}
	for _, tc := range bodyCases {
		t.Run("body/"+tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, "http://relay.example/", nil)
			r.ContentLength = tc.length
			if tc.contentType != "" {
				r.Header.Set("Content-Type", tc.contentType)
			}
			if got := adminRequestHasJSONBody(r); got != tc.want {
				t.Fatalf("JSON body result = %v, want %v", got, tc.want)
			}
		})
	}

	plain := httptest.NewRequest(http.MethodGet, "http://relay.example/", nil)
	if requestUsesTLS(plain) || requestScheme(plain) != "http" {
		t.Fatal("plain request incorrectly reported as TLS")
	}
	plain.Header.Set("X-Forwarded-Proto", "HTTPS")
	if !requestUsesTLS(plain) || requestScheme(plain) != "https" {
		t.Fatal("forwarded HTTPS was not recognized")
	}
}

func TestAdminLoginLimiterEvictsOldestEntry(t *testing.T) {
	server := NewServer(Config{
		MaxAdminLoginEntries:    1,
		AdminLoginMaxAttempts:   5,
		AdminLoginWindow:        time.Minute,
		AdminLoginBlockDuration: time.Minute,
	})
	defer server.Close()
	oldKey := adminLoginKey("198.51.100.10", "old")
	server.admin.loginAttempts[oldKey] = adminLoginAttempt{lastSeen: time.Now().Add(-time.Minute)}
	if allowed, _ := server.allowAdminLogin("198.51.100.11", "new"); !allowed {
		t.Fatal("new login entry should be admitted after evicting the oldest entry")
	}
	if _, present := server.admin.loginAttempts[oldKey]; present {
		t.Fatal("oldest login limiter entry was not evicted")
	}
}

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
	store := newMemoryStore(Config{MaxAdminSessions: 2})

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

	if exists, err := store.AdminSessionExists(ctx, "missing"); err != nil || exists {
		t.Fatalf("missing admin session = %v, err=%v", exists, err)
	}
	if err := store.SetAdminSession(ctx, "expired", -time.Second); err != nil {
		t.Fatal(err)
	}
	if exists, err := store.AdminSessionExists(ctx, "expired"); err != nil || exists {
		t.Fatalf("expired admin session = %v, err=%v", exists, err)
	}
	if err := store.SetAdminSession(ctx, "live", time.Minute); err != nil {
		t.Fatal(err)
	}
	if exists, err := store.AdminSessionExists(ctx, "live"); err != nil || !exists {
		t.Fatalf("live admin session = %v, err=%v", exists, err)
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
	if renewed, err := store.RenewReservation(ctx, "missing", time.Minute); err != nil || renewed {
		t.Fatalf("missing reservation renewal = %v, err=%v", renewed, err)
	}
	if err := store.DeleteReservation(ctx, reservation.ReservationID); err != nil {
		t.Fatal(err)
	}
	if _, present, err := store.GetReservation(ctx, reservation.ReservationID); err != nil || present {
		t.Fatalf("deleted reservation = present=%v err=%v", present, err)
	}
}

func TestRedisStoreGetDiscoveriesBatchBoundaries(t *testing.T) {
	ctx := context.Background()
	store, err := openRedisStore(ctx, requireRedisURL(t))
	if err != nil {
		t.Fatalf("open redis: %v", err)
	}
	defer store.Close()
	keys := []string{store.discoveryKey("batch-live"), store.discoveryKey("batch-corrupt")}
	if err := store.client.Del(ctx, keys...).Err(); err != nil {
		t.Fatal(err)
	}
	defer store.client.Del(ctx, keys...)

	if _, _, err := store.TakePresence(ctx, "batch-live", "batch-conn", Presence{}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := store.TakeDiscovery(ctx, "batch-live", "batch-conn", Discovery{
		DeviceID:     "batch-live",
		ConnectionID: "batch-conn",
		Revision:     1,
	}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := store.client.Set(ctx, store.discoveryKey("batch-corrupt"), "{not-json", time.Minute).Err(); err != nil {
		t.Fatal(err)
	}
	if empty, err := store.GetDiscoveries(ctx, nil); err != nil || empty == nil || len(empty) != 0 {
		t.Fatalf("empty redis discovery batch = %+v, err=%v", empty, err)
	}
	got, err := store.GetDiscoveries(ctx, []string{"batch-live", "batch-missing", "batch-corrupt"})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got["batch-live"].Revision != 1 {
		t.Fatalf("redis batch discovery result = %+v, want only live entry", got)
	}
}

func TestRedisStoreLeaseAndReservationBoundaries(t *testing.T) {
	ctx := context.Background()
	store, err := openRedisStore(ctx, requireRedisURL(t))
	if err != nil {
		t.Fatalf("open redis: %v", err)
	}
	defer store.Close()
	deviceID := "boundary-device"
	reservationID := "boundary-reservation"
	defer func() {
		_ = store.forceDeletePresence(ctx, deviceID)
		_ = store.client.Del(ctx, store.discoveryKey(deviceID), store.reservationKey(reservationID)).Err()
	}()
	if _, present, err := store.GetPresence(ctx, deviceID); err != nil || present {
		t.Fatalf("missing redis presence = present=%v err=%v", present, err)
	}
	if _, _, err := store.TakePresence(ctx, deviceID, "owner", Presence{}, time.Minute); err != nil {
		t.Fatal(err)
	}
	if renewed, err := store.RenewPresence(ctx, deviceID, "foreign", Presence{}, time.Minute); err != nil || renewed {
		t.Fatalf("foreign redis presence renewal = %v, err=%v", renewed, err)
	}
	if released, err := store.ReleasePresence(ctx, deviceID, "foreign"); err != nil || released {
		t.Fatalf("foreign redis presence release = %v, err=%v", released, err)
	}
	if released, err := store.ReleasePresence(ctx, deviceID, "owner"); err != nil || !released {
		t.Fatalf("owner redis presence release = %v, err=%v", released, err)
	}

	if renewed, err := store.RenewDiscovery(ctx, deviceID, "owner", time.Minute); err != nil || !renewed {
		t.Fatalf("missing redis discovery renewal = %v, err=%v", renewed, err)
	}
	if _, _, err := store.TakePresence(ctx, deviceID, "owner", Presence{}, time.Minute); err != nil {
		t.Fatal(err)
	}
	discovery := Discovery{DeviceID: deviceID, ConnectionID: "owner", Revision: 1}
	if err := store.TakeDiscovery(ctx, deviceID, "foreign", discovery, time.Minute); err != errDiscoveryNotOwner {
		t.Fatalf("foreign redis discovery take = %v, want ownership error", err)
	}
	if err := store.TakeDiscovery(ctx, deviceID, "owner", discovery, time.Minute); err != nil {
		t.Fatal(err)
	}
	if renewed, err := store.RenewDiscovery(ctx, deviceID, "foreign", time.Minute); err != nil || renewed {
		t.Fatalf("foreign redis discovery renewal = %v, err=%v", renewed, err)
	}
	if renewed, err := store.RenewDiscovery(ctx, deviceID, "owner", time.Minute); err != nil || !renewed {
		t.Fatalf("owner redis discovery renewal = %v, err=%v", renewed, err)
	}
	if released, err := store.ReleaseDiscovery(ctx, deviceID, "foreign"); err != nil || released {
		t.Fatalf("foreign redis discovery release = %v, err=%v", released, err)
	}
	if err := store.client.Set(ctx, store.discoveryKey(deviceID), "{bad-json", time.Minute).Err(); err != nil {
		t.Fatal(err)
	}
	if _, present, err := store.GetDiscovery(ctx, deviceID); err == nil || present {
		t.Fatalf("corrupt redis discovery = present=%v err=%v", present, err)
	}

	reservation := Reservation{ReservationID: reservationID, ExpiresAtMs: time.Now().Add(time.Minute).UnixMilli()}
	if err := store.CreateReservation(ctx, reservation); err != nil {
		t.Fatal(err)
	}
	if got, present, err := store.GetReservation(ctx, reservationID); err != nil || !present || got.ReservationID != reservationID {
		t.Fatalf("redis reservation read = %+v present=%v err=%v", got, present, err)
	}
	if renewed, err := store.RenewReservation(ctx, reservationID, 0); err != nil || renewed {
		t.Fatalf("zero redis reservation renewal = %v, err=%v", renewed, err)
	}
	if renewed, err := store.RenewReservation(ctx, reservationID, time.Minute); err != nil || !renewed {
		t.Fatalf("redis reservation renewal = %v, err=%v", renewed, err)
	}
	if err := store.DeleteReservation(ctx, reservationID); err != nil {
		t.Fatal(err)
	}
	if _, present, err := store.GetReservation(ctx, reservationID); err != nil || present {
		t.Fatalf("deleted redis reservation = present=%v err=%v", present, err)
	}
	expired := Reservation{ReservationID: "expired-reservation", ExpiresAtMs: time.Now().Add(-time.Hour).UnixMilli()}
	if err := store.CreateReservation(ctx, expired); err == nil {
		t.Fatal("expired redis reservation was accepted")
	}
}

func TestOpenRedisStoreRejectsMalformedURL(t *testing.T) {
	if _, err := openRedisStore(context.Background(), "://not-a-url"); err == nil {
		t.Fatal("malformed Redis URL was accepted")
	}
}

func TestRelayReservationValidationBoundaries(t *testing.T) {
	validID := strings.Repeat("ab", 16)
	for _, tc := range []struct {
		name string
		id   string
		want bool
	}{
		{name: "valid lowercase hex", id: validID, want: true},
		{name: "uppercase is rejected", id: strings.ToUpper(validID), want: false},
		{name: "wrong length", id: validID[:30], want: false},
		{name: "non hex", id: strings.Repeat("zz", 16), want: false},
	} {
		t.Run("id/"+tc.name, func(t *testing.T) {
			if got := validReservationID(tc.id); got != tc.want {
				t.Fatalf("validReservationID(%q) = %v, want %v", tc.id, got, tc.want)
			}
		})
	}

	initiator := []byte(strings.Repeat("\x11", 32))
	responder := []byte(strings.Repeat("\x22", 32))
	reservation := Reservation{InitiatorToken: initiator, ResponderToken: responder}
	initiatorHex := hex.EncodeToString(initiator)
	responderHex := hex.EncodeToString(responder)
	cases := []struct {
		name    string
		query   string
		header  string
		role    relayDataRole
		want    bool
		anyRole bool
	}{
		{name: "query initiator", query: initiatorHex, role: relayDataRoleInitiator, want: true},
		{name: "header responder", header: responderHex, role: relayDataRoleResponder, want: true},
		{name: "missing token", role: relayDataRoleInitiator},
		{name: "invalid hex", query: "not-hex", role: relayDataRoleInitiator},
		{name: "mismatched query and header", query: initiatorHex, header: responderHex, role: relayDataRoleInitiator},
		{name: "wrong role token", query: responderHex, role: relayDataRoleInitiator},
		{name: "unknown role", query: initiatorHex, role: relayDataRole(99)},
		{name: "any role wrapper", query: responderHex, anyRole: true, want: true},
	}
	for _, tc := range cases {
		t.Run("token/"+tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodGet, "http://relay.example/v2/relay/id", nil)
			if tc.query != "" {
				r.URL.RawQuery = "token=" + tc.query
			}
			if tc.header != "" {
				r.Header.Set("X-Relay-Token", tc.header)
			}
			got := validRelayTokenForRole(r, reservation, tc.role)
			if tc.anyRole {
				got = validRelayToken(r, reservation)
			}
			if got != tc.want {
				t.Fatalf("token validation = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestDiscoverySetAndRoleBoundaries(t *testing.T) {
	for _, tc := range []struct {
		name string
		a    []string
		b    []string
		want bool
	}{
		{name: "same members different order", a: []string{"a", "b"}, b: []string{"b", "a"}, want: true},
		{name: "different length", a: []string{"a"}, b: []string{"a", "b"}, want: false},
		{name: "missing member", a: []string{"a", "b"}, b: []string{"a", "c"}, want: false},
		{name: "duplicate multiplicity differs", a: []string{"a", "a"}, b: []string{"a", "b"}, want: false},
	} {
		t.Run("set/"+tc.name, func(t *testing.T) {
			if got := sameStringSet(tc.a, tc.b); got != tc.want {
				t.Fatalf("sameStringSet(%v, %v) = %v, want %v", tc.a, tc.b, got, tc.want)
			}
		})
	}

	reservation := Reservation{InitiatorDeviceID: "device-a", ResponderDeviceID: "device-b"}
	for _, tc := range []struct {
		name   string
		device string
		role   relayDataRole
		want   bool
	}{
		{name: "initiator", device: "device-a", role: relayDataRoleInitiator, want: true},
		{name: "responder", device: "device-b", role: relayDataRoleResponder, want: true},
		{name: "unknown", device: "device-c", want: false},
		{name: "empty", device: "", want: false},
		{name: "initiator role is stable", device: "device-a", role: relayDataRoleInitiator, want: true},
	} {
		t.Run("role/"+tc.name, func(t *testing.T) {
			got, ok := relayDataRoleForDevice(reservation, tc.device)
			if ok != tc.want || (ok && got != tc.role) {
				t.Fatalf("relayDataRoleForDevice(%q) = (%v, %v), want (%v, %v)", tc.device, got, ok, tc.role, tc.want)
			}
		})
	}
	reservation.ResponderDeviceID = reservation.InitiatorDeviceID
	if _, ok := relayDataRoleForDevice(reservation, "device-a"); ok {
		t.Fatal("reservation with identical endpoint devices should be rejected")
	}
}

func TestHealthIsUncachedNoContent(t *testing.T) {
	server := NewServer(Config{})
	defer server.Close()
	response := httptest.NewRecorder()
	server.health(response, httptest.NewRequest(http.MethodGet, "/health", nil))
	if response.Code != http.StatusNoContent {
		t.Fatalf("health status = %d, want 204", response.Code)
	}
	if response.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("health cache header = %q, want no-store", response.Header().Get("Cache-Control"))
	}
}
