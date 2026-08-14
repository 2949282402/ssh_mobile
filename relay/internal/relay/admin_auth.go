package relay

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"mime"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

type adminLoginAttempt struct {
	windowStartedAt time.Time
	attempts        int
	blockedUntil    time.Time
	lastSeen        time.Time
}

type adminAuthState struct {
	user          string
	passwordHash  [sha256.Size]byte
	configured    bool
	loginAttempts map[string]adminLoginAttempt
	mutex         sync.Mutex
}

type adminLoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type adminSessionResponse struct {
	Authenticated bool   `json:"authenticated"`
	Username      string `json:"username"`
}

func (s *Server) tryCreateAdminSession() (string, bool) {
	token := hex.EncodeToString(randomBytes(32))
	if err := s.cache.SetAdminSession(context.Background(), token, s.config.AdminSessionTTL); err != nil {
		// 内存模式容量耗尽返回 errAdminSessionCapacity；其余错误（如 Redis 故障）
		// 一律 fail closed，管理端登录失败。
		return "", false
	}
	return token, true
}

func (s *Server) destroyAdminSession(token string) {
	_ = s.cache.DeleteAdminSession(context.Background(), token)
}

func (s *Server) isAdminAuthorized(r *http.Request) bool {
	token := ""
	if cookie, err := r.Cookie("relay_session"); err == nil {
		token = cookie.Value
	} else {
		token = strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	}
	if token == "" {
		return false
	}
	valid, err := s.cache.AdminSessionExists(context.Background(), token)
	if err != nil {
		// Redis 故障时管理端鉴权 fail closed（管理面非设备核心面）。
		return false
	}
	return valid
}

func (s *Server) adminAuthMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.isAdminAuthorized(r) {
			writeAdminError(w, http.StatusUnauthorized, adminErrorUnauthorized, "Administrator authentication failed.")
			return
		}
		next(w, r)
	}
}

// adminResponseHeaders applies response protections to every administrative
// endpoint without changing the device-plane v1 response contract.
func adminResponseHeaders(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Add("Vary", "Origin")
		w.Header().Add("Vary", "Sec-Fetch-Site")
		next(w, r)
	}
}

// adminStateChangeMiddleware rejects browser cross-site mutations. Empty-body
// mutations remain valid for the existing logout/revoke/rotate endpoints; any
// request that carries a body must declare application/json.
func adminStateChangeMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !adminRequestIsSameOrigin(r) {
			writeAdminError(w, http.StatusForbidden, adminErrorForbidden, "Administrator request origin is not allowed.")
			return
		}
		if !adminRequestHasJSONBody(r) {
			writeAdminError(w, http.StatusUnsupportedMediaType, adminErrorInvalidRequest, "Administrator request content type is invalid.")
			return
		}
		next(w, r)
	}
}

func (s *Server) adminLoginHandler(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	var request adminLoginRequest
	if json.NewDecoder(r.Body).Decode(&request) != nil {
		writeAdminError(w, http.StatusBadRequest, adminErrorInvalidRequest, "Login request is invalid.")
		return
	}
	clientIP := s.requestClientIP(r)
	if allowed, retryAfter := s.allowAdminLogin(clientIP, request.Username); !allowed {
		writeAdminRateLimit(w, retryAfter)
		return
	}

	s.admin.mutex.Lock()
	candidatePasswordHash := passwordDigest(s.config.CredentialKey, request.Password)
	valid := s.admin.configured &&
		hmac.Equal([]byte(request.Username), []byte(s.admin.user)) &&
		hmac.Equal(candidatePasswordHash[:], s.admin.passwordHash[:])
	username := s.admin.user
	s.admin.mutex.Unlock()

	if !valid {
		writeAdminError(w, http.StatusUnauthorized, adminErrorUnauthorized, "Administrator authentication failed.")
		return
	}

	s.clearAdminLoginLimit(clientIP, request.Username)
	token, created := s.tryCreateAdminSession()
	if !created {
		writeAdminError(w, http.StatusTooManyRequests, adminErrorResourceLimit, "Administrator session capacity is temporarily exhausted.")
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     "relay_session",
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		Secure:   requestUsesTLS(r),
		SameSite: http.SameSiteLaxMode,
		MaxAge:   int(s.config.AdminSessionTTL / time.Second),
	})

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"username": username})
}

func (s *Server) adminLogoutHandler(w http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie("relay_session"); err == nil && cookie.Value != "" {
		s.destroyAdminSession(cookie.Value)
	}
	http.SetCookie(w, &http.Cookie{
		Name:     "relay_session",
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		Secure:   requestUsesTLS(r),
		SameSite: http.SameSiteLaxMode,
		MaxAge:   -1,
	})
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) adminSessionHandler(w http.ResponseWriter, r *http.Request) {
	authenticated := s.isAdminAuthorized(r)
	username := ""
	if authenticated {
		s.admin.mutex.Lock()
		username = s.admin.user
		s.admin.mutex.Unlock()
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(adminSessionResponse{
		Authenticated: authenticated,
		Username:      username,
	})
}

func (s *Server) allowAdminLogin(clientIP, username string) (bool, time.Duration) {
	now := time.Now()
	key := adminLoginKey(clientIP, username)
	s.admin.mutex.Lock()
	defer s.admin.mutex.Unlock()

	for current, attempt := range s.admin.loginAttempts {
		if now.Sub(attempt.lastSeen) >= s.config.AdminLoginWindow && !now.Before(attempt.blockedUntil) {
			delete(s.admin.loginAttempts, current)
		}
	}
	attempt, exists := s.admin.loginAttempts[key]
	if exists && now.Before(attempt.blockedUntil) {
		attempt.lastSeen = now
		s.admin.loginAttempts[key] = attempt
		return false, attempt.blockedUntil.Sub(now)
	}
	if !exists || now.Sub(attempt.windowStartedAt) >= s.config.AdminLoginWindow {
		attempt = adminLoginAttempt{windowStartedAt: now}
	}
	if attempt.attempts >= s.config.AdminLoginMaxAttempts {
		attempt.blockedUntil = now.Add(s.config.AdminLoginBlockDuration)
		attempt.lastSeen = now
		s.admin.loginAttempts[key] = attempt
		return false, s.config.AdminLoginBlockDuration
	}
	attempt.attempts++
	attempt.lastSeen = now
	if !exists && len(s.admin.loginAttempts) >= s.config.MaxAdminLoginEntries {
		s.evictOldestLoginLimitLocked()
	}
	s.admin.loginAttempts[key] = attempt
	return true, 0
}

func (s *Server) clearAdminLoginLimit(clientIP, username string) {
	s.admin.mutex.Lock()
	delete(s.admin.loginAttempts, adminLoginKey(clientIP, username))
	s.admin.mutex.Unlock()
}

func (s *Server) evictOldestLoginLimitLocked() {
	var oldestKey string
	var oldest time.Time
	for key, attempt := range s.admin.loginAttempts {
		if oldestKey == "" || attempt.lastSeen.Before(oldest) {
			oldestKey = key
			oldest = attempt.lastSeen
		}
	}
	if oldestKey != "" {
		delete(s.admin.loginAttempts, oldestKey)
	}
}

func adminLoginKey(clientIP, username string) string {
	return strings.TrimSpace(clientIP) + "\x00" + strings.ToLower(strings.TrimSpace(username))
}

func writeAdminRateLimit(w http.ResponseWriter, retryAfter time.Duration) {
	seconds := int64((retryAfter + time.Second - 1) / time.Second)
	if seconds < 1 {
		seconds = 1
	}
	w.Header().Set("Retry-After", strconv.FormatInt(seconds, 10))
	writeAdminError(w, http.StatusTooManyRequests, adminErrorRateLimited, "Too many administrator login attempts. Try again later.")
}

// requestClientIP resolves the client IP for the login limiter. The immediate
// peer (RemoteAddr) is authoritative by default; forwarding headers are honored
// only when the peer itself is an explicitly configured trusted proxy. This
// prevents a direct deployment from evading the per-client-IP limiter by
// rotating X-Forwarded-For / X-Real-IP.
func (s *Server) requestClientIP(r *http.Request) string {
	peer, ok := remoteIP(r.RemoteAddr)
	if !ok {
		return "unknown"
	}
	if !s.isTrustedProxy(peer) {
		return peer.String()
	}
	// The peer is a trusted proxy. Walk X-Forwarded-For from the right, which
	// is where the closest trusted proxy appends the address it saw, skipping
	// entries that are themselves trusted proxies so a spoofed leftward chain
	// cannot pick a forged address.
	if forwarded := r.Header.Get("X-Forwarded-For"); forwarded != "" {
		parts := strings.Split(forwarded, ",")
		for i := len(parts) - 1; i >= 0; i-- {
			candidate, err := netip.ParseAddr(strings.TrimSpace(parts[i]))
			if err != nil {
				continue
			}
			if !s.isTrustedProxy(candidate) {
				return candidate.String()
			}
		}
	}
	if realIP := r.Header.Get("X-Real-IP"); realIP != "" {
		if candidate, err := netip.ParseAddr(strings.TrimSpace(realIP)); err == nil && !s.isTrustedProxy(candidate) {
			return candidate.String()
		}
	}
	return peer.String()
}

// remoteIP extracts the IP address from an HTTP RemoteAddr that may or may not
// include a port.
func remoteIP(remoteAddr string) (netip.Addr, bool) {
	trimmed := strings.TrimSpace(remoteAddr)
	if host, _, err := net.SplitHostPort(trimmed); err == nil {
		if ip, err := netip.ParseAddr(host); err == nil {
			return ip, true
		}
	}
	if ip, err := netip.ParseAddr(trimmed); err == nil {
		return ip, true
	}
	return netip.Addr{}, false
}

// isTrustedProxy reports whether addr is covered by the configured
// RELAY_TRUSTED_PROXY_CIDRS boundary.
func (s *Server) isTrustedProxy(addr netip.Addr) bool {
	for _, prefix := range s.config.TrustedProxyCIDRs {
		if prefix.Contains(addr) {
			return true
		}
	}
	return false
}

func adminRequestIsSameOrigin(r *http.Request) bool {
	site := strings.ToLower(strings.TrimSpace(r.Header.Get("Sec-Fetch-Site")))
	switch site {
	case "", "same-origin", "same-site", "none":
	default:
		return false
	}

	origin := strings.TrimSpace(r.Header.Get("Origin"))
	if origin == "" {
		return true
	}
	parsed, err := url.Parse(origin)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" || parsed.User != nil || parsed.Path != "" || parsed.RawQuery != "" || parsed.Fragment != "" {
		return false
	}
	return strings.EqualFold(parsed.Scheme, requestScheme(r)) && strings.EqualFold(parsed.Host, r.Host)
}

func adminRequestHasJSONBody(r *http.Request) bool {
	contentType := strings.TrimSpace(r.Header.Get("Content-Type"))
	if contentType == "" && r.ContentLength == 0 {
		return true
	}
	mediaType, _, err := mime.ParseMediaType(contentType)
	return err == nil && strings.EqualFold(mediaType, "application/json")
}

func passwordDigest(key []byte, password string) [sha256.Size]byte {
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(password))
	var digest [sha256.Size]byte
	copy(digest[:], mac.Sum(nil))
	return digest
}

func requestUsesTLS(r *http.Request) bool {
	return r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")
}

func requestScheme(r *http.Request) string {
	if requestUsesTLS(r) {
		return "https"
	}
	return "http"
}
