// HTTP middlewares for security headers, same-origin CSRF, and authentication.

package admin

import (
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
)

func (s *Server) clientIP(r *http.Request) string {
	remoteHost, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		remoteHost = r.RemoteAddr
	}
	remoteAddr, err := netip.ParseAddr(remoteHost)
	if err != nil {
		return remoteHost
	}

	trusted := false
	for _, prefix := range s.config.TrustedProxyCIDRs {
		if prefix.Contains(remoteAddr) {
			trusted = true
			break
		}
	}
	if !trusted {
		return remoteHost
	}

	xff := r.Header.Get("X-Forwarded-For")
	if xff != "" {
		parts := strings.Split(xff, ",")
		if len(parts) > 0 {
			clientPart := strings.TrimSpace(parts[0])
			if parsed, err := netip.ParseAddr(clientPart); err == nil {
				return parsed.String()
			}
		}
	}
	return remoteHost
}

func (s *Server) requestUsesTLS(r *http.Request) bool {
	if r.TLS != nil {
		return true
	}
	remoteHost, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		remoteHost = r.RemoteAddr
	}
	remoteAddr, err := netip.ParseAddr(remoteHost)
	if err != nil {
		return false
	}
	for _, prefix := range s.config.TrustedProxyCIDRs {
		if prefix.Contains(remoteAddr) {
			proto := strings.ToLower(r.Header.Get("X-Forwarded-Proto"))
			return proto == "https"
		}
	}
	return false
}

func (s *Server) adminResponseHeaders(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'; base-uri 'none'")
		if s.requestUsesTLS(r) {
			w.Header().Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
		}
		next(w, r)
	}
}

func (s *Server) adminStateChangeMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost || r.Method == http.MethodPut || r.Method == http.MethodDelete || r.Method == http.MethodPatch {
			// Require application/json on state-changing requests with body
			if r.Body != nil && r.ContentLength != 0 {
				ct := r.Header.Get("Content-Type")
				if !strings.HasPrefix(strings.ToLower(ct), "application/json") {
					writeAdminError(w, http.StatusUnsupportedMediaType, adminErrorInvalidRequest, "Administrator request content type is invalid.")
					return
				}
			}

			// Same-origin check
			origin := r.Header.Get("Origin")
			if origin != "" {
				originURL, err := url.Parse(origin)
				if err != nil || originURL.Host != r.Host {
					writeAdminError(w, http.StatusForbidden, adminErrorAuthenticationFailed, "Same-origin verification failed.")
					return
				}
			}
		}
		next(w, r)
	}
}

func (s *Server) adminAuthMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie(sessionCookieName)
		if err != nil || cookie.Value == "" {
			writeAdminError(w, http.StatusUnauthorized, adminErrorAuthenticationFailed, "Administrator authentication required.")
			return
		}

		exists, err := s.sessionStore.Exists(r.Context(), cookie.Value)
		if err != nil {
			writeAdminError(w, http.StatusServiceUnavailable, adminErrorInternal, "Failed to verify administrator session.")
			return
		}
		if !exists {
			writeAdminError(w, http.StatusUnauthorized, adminErrorAuthenticationFailed, "Administrator session has expired or is invalid.")
			return
		}

		next(w, r)
	}
}
