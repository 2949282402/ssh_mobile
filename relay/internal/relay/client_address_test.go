package relay

import (
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
)

func TestClientRemoteAddrUsesForwardedAddressOnlyFromTrustedProxy(t *testing.T) {
	trustedProxies := []netip.Prefix{netip.MustParsePrefix("172.30.0.10/32")}
	cases := []struct {
		name      string
		remote    string
		forwarded string
		want      string
	}{
		{
			name:      "direct client ignores spoofed header",
			remote:    "198.51.100.9:4567",
			forwarded: "203.0.113.7:43120",
			want:      "198.51.100.9:4567",
		},
		{
			name:      "trusted proxy forwards client address",
			remote:    "172.30.0.10:6000",
			forwarded: "203.0.113.7:43120",
			want:      "203.0.113.7:43120",
		},
		{
			name:      "trusted proxy accepts ipv6 client address",
			remote:    "172.30.0.10:6000",
			forwarded: "[2001:db8::9]:443",
			want:      "[2001:db8::9]:443",
		},
		{
			name:      "trusted proxy rejects malformed client address",
			remote:    "172.30.0.10:6000",
			forwarded: "not-an-address",
			want:      "172.30.0.10:6000",
		},
		{
			name:      "untrusted proxy address ignores forwarded value",
			remote:    "192.0.2.10:6000",
			forwarded: "203.0.113.7:43120",
			want:      "192.0.2.10:6000",
		},
		{
			name:      "unparseable request address falls back without trusting header",
			remote:    "not-an-address",
			forwarded: "203.0.113.7:43120",
			want:      "not-an-address",
		},
		{
			name:      "trusted proxy rejects non-ip forwarded address",
			remote:    "172.30.0.10:6000",
			forwarded: "not-an-ip:43120",
			want:      "172.30.0.10:6000",
		},
	}

	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, PathControlV2, nil)
			request.RemoteAddr = test.remote
			request.Header.Set(forwardedClientAddrHeader, test.forwarded)

			if got := clientRemoteAddr(request, trustedProxies); got != test.want {
				t.Fatalf("clientRemoteAddr() = %q, want %q", got, test.want)
			}
		})
	}
}

func TestClientRemoteAddrFallsBackToRequestRemoteAddr(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, PathControlV2, nil)
	request.RemoteAddr = "198.51.100.9:4567"

	if got := clientRemoteAddr(request, nil); got != request.RemoteAddr {
		t.Fatalf("clientRemoteAddr() = %q, want %q", got, request.RemoteAddr)
	}
}

func TestClientRemoteAddrHandlesNilRequest(t *testing.T) {
	if got := clientRemoteAddr(nil, nil); got != "" {
		t.Fatalf("clientRemoteAddr(nil) = %q, want empty string", got)
	}
}

func TestPresenceForUsesForwardedClientAddress(t *testing.T) {
	hub := &hub{}
	peer := &peer{
		connectionID: "connection-a",
		remoteAddr:   "203.0.113.7:43120",
	}

	presence := hub.presenceFor(peer)
	if presence.RemoteAddr != peer.remoteAddr {
		t.Fatalf("presence remote address = %q, want %q", presence.RemoteAddr, peer.remoteAddr)
	}
}
