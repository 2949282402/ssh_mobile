// Administrator authentication, password hashing, and session handlers.

package admin

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"sync"
	"time"
)

const sessionCookieName = "relay_session"

type adminLoginAttempt struct {
	attempts    int
	windowStart time.Time
	blockedTo   time.Time
}

type adminAuthState struct {
	user          string
	passwordHash  []byte
	configured    bool
	mu            sync.Mutex
	loginAttempts map[string]adminLoginAttempt
}

func passwordDigest(authKey []byte, password string) []byte {
	mac := hmac.New(sha256.New, authKey)
	mac.Write([]byte(password))
	return mac.Sum(nil)
}

func (s *Server) adminLoginHandler(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()
	r.Body = http.MaxBytesReader(w, r.Body, 4096)

	var payload struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		writeAdminError(w, http.StatusBadRequest, adminErrorInvalidRequest, "Administrator request is invalid.")
		return
	}

	ip := s.clientIP(r)
	if s.isLoginBlocked(ip) {
		writeAdminError(w, http.StatusTooManyRequests, adminErrorResourceLimit, "Too many failed login attempts; retry later.")
		return
	}

	if !s.admin.configured {
		writeAdminError(w, http.StatusServiceUnavailable, adminErrorAuthenticationFailed, "Administrator authentication is not configured.")
		return
	}

	userMatch := s.admin.user != "" && hmac.Equal([]byte(payload.Username), []byte(s.admin.user))
	presentedHash := passwordDigest(s.config.AuthKey, payload.Password)
	passwordMatch := len(s.admin.passwordHash) > 0 && hmac.Equal(presentedHash, s.admin.passwordHash)

	if !userMatch || !passwordMatch {
		s.recordLoginFailure(ip)
		writeAdminError(w, http.StatusUnauthorized, adminErrorAuthenticationFailed, "Invalid administrator credentials.")
		return
	}

	s.clearLoginFailures(ip)

	token := hex.EncodeToString(randomBytes(32))
	if err := s.sessionStore.Create(r.Context(), token, s.config.SessionTTL); err != nil {
		if errors.Is(err, errSessionCapacity) {
			writeAdminError(w, http.StatusTooManyRequests, adminErrorResourceLimit, "Administrator session capacity reached.")
			return
		}
		writeAdminError(w, http.StatusServiceUnavailable, adminErrorInternal, "Failed to create administrator session.")
		return
	}

	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookieName,
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   s.requestUsesTLS(r),
		MaxAge:   int(s.config.SessionTTL.Seconds()),
	})

	_ = json.NewEncoder(w).Encode(map[string]bool{"authenticated": true})
}

func (s *Server) adminLogoutHandler(w http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie(sessionCookieName); err == nil && cookie.Value != "" {
		_ = s.sessionStore.Delete(r.Context(), cookie.Value)
	}

	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookieName,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   s.requestUsesTLS(r),
		MaxAge:   -1,
	})

	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) adminSessionHandler(w http.ResponseWriter, r *http.Request) {
	authenticated := false
	if cookie, err := r.Cookie(sessionCookieName); err == nil && cookie.Value != "" {
		if exists, _ := s.sessionStore.Exists(r.Context(), cookie.Value); exists {
			authenticated = true
		}
	}

	_ = json.NewEncoder(w).Encode(map[string]bool{"authenticated": authenticated})
}

func (s *Server) isLoginBlocked(ip string) bool {
	s.admin.mu.Lock()
	defer s.admin.mu.Unlock()

	attempt, exists := s.admin.loginAttempts[ip]
	if !exists {
		return false
	}
	now := time.Now()
	if !attempt.blockedTo.IsZero() && now.Before(attempt.blockedTo) {
		return true
	}
	return false
}

func (s *Server) recordLoginFailure(ip string) {
	s.admin.mu.Lock()
	defer s.admin.mu.Unlock()

	now := time.Now()
	attempt, exists := s.admin.loginAttempts[ip]
	if !exists || now.Sub(attempt.windowStart) > s.config.LoginWindow {
		attempt = adminLoginAttempt{
			attempts:    1,
			windowStart: now,
		}
	} else {
		attempt.attempts++
	}

	if attempt.attempts >= s.config.LoginMaxAttempts {
		attempt.blockedTo = now.Add(s.config.LoginBlockDuration)
	}

	if len(s.admin.loginAttempts) >= s.config.MaxLoginEntries {
		for k, v := range s.admin.loginAttempts {
			if now.Sub(v.windowStart) > s.config.LoginWindow && (v.blockedTo.IsZero() || now.After(v.blockedTo)) {
				delete(s.admin.loginAttempts, k)
			}
		}
	}

	if len(s.admin.loginAttempts) < s.config.MaxLoginEntries {
		s.admin.loginAttempts[ip] = attempt
	}
}

func (s *Server) clearLoginFailures(ip string) {
	s.admin.mu.Lock()
	defer s.admin.mu.Unlock()
	delete(s.admin.loginAttempts, ip)
}
