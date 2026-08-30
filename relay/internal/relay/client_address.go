package relay

import (
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
)

// forwardedClientAddrHeader is set by the public reverse proxy. It carries the
// source address before proxying so the admin device view can show the actual
// client IP and port instead of the proxy's internal socket.
const forwardedClientAddrHeader = "X-Relay-Client-Addr"

// clientRemoteAddr returns the address to persist in device presence. A
// forwarding header is accepted only when the immediate HTTP peer belongs to
// the explicitly configured trusted-proxy boundary; direct clients cannot
// spoof another device's address.
func clientRemoteAddr(request *http.Request, trustedProxies []netip.Prefix) string {
	if request == nil {
		return ""
	}
	fallback := strings.TrimSpace(request.RemoteAddr)
	peer, ok := remoteIP(request.RemoteAddr)
	if !ok || !isTrustedProxy(peer, trustedProxies) {
		return fallback
	}
	if forwarded, valid := parseClientSocketAddr(request.Header.Get(forwardedClientAddrHeader)); valid {
		return forwarded
	}
	return fallback
}

func remoteIP(remoteAddr string) (netip.Addr, bool) {
	trimmed := strings.TrimSpace(remoteAddr)
	if host, _, err := net.SplitHostPort(trimmed); err == nil {
		if ip, err := netip.ParseAddr(host); err == nil {
			return ip.Unmap(), true
		}
	}
	if ip, err := netip.ParseAddr(trimmed); err == nil {
		return ip.Unmap(), true
	}
	return netip.Addr{}, false
}

func isTrustedProxy(addr netip.Addr, trustedProxies []netip.Prefix) bool {
	for _, prefix := range trustedProxies {
		if prefix.Contains(addr) {
			return true
		}
	}
	return false
}

func parseClientSocketAddr(raw string) (string, bool) {
	host, port, err := net.SplitHostPort(strings.TrimSpace(raw))
	if err != nil {
		return "", false
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return "", false
	}
	portNumber, err := strconv.ParseUint(port, 10, 16)
	if err != nil || portNumber == 0 {
		return "", false
	}
	return net.JoinHostPort(ip.String(), strconv.Itoa(int(portNumber))), true
}
