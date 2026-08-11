package relay

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"time"
)

type adminAuthState struct {
	user         string
	passwordHash [sha256.Size]byte
	configured   bool
	sessions     map[string]time.Time
	mutex        sync.Mutex
}

type adminLoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type adminSessionResponse struct {
	Authenticated bool   `json:"authenticated"`
	Username      string `json:"username"`
}

func (s *Server) createAdminSession() string {
	token := hex.EncodeToString(randomBytes(32))
	s.admin.mutex.Lock()
	defer s.admin.mutex.Unlock()
	now := time.Now()
	for current, expiresAt := range s.admin.sessions {
		if now.After(expiresAt) {
			delete(s.admin.sessions, current)
		}
	}
	s.admin.sessions[token] = now.Add(s.config.AdminSessionTTL)
	return token
}

func (s *Server) destroyAdminSession(token string) {
	s.admin.mutex.Lock()
	defer s.admin.mutex.Unlock()
	delete(s.admin.sessions, token)
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

	s.admin.mutex.Lock()
	defer s.admin.mutex.Unlock()
	expiresAt, found := s.admin.sessions[token]
	if !found || time.Now().After(expiresAt) {
		if found {
			delete(s.admin.sessions, token)
		}
		return false
	}
	return true
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

func (s *Server) adminLoginHandler(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	var request adminLoginRequest
	if json.NewDecoder(r.Body).Decode(&request) != nil {
		writeAdminError(w, http.StatusBadRequest, adminErrorInvalidRequest, "Login request is invalid.")
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

	token := s.createAdminSession()
	http.SetCookie(w, &http.Cookie{
		Name:     "relay_session",
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		Secure:   requestUsesTLS(r),
		SameSite: http.SameSiteLaxMode,
		MaxAge:   int(s.config.AdminSessionTTL / time.Second),
	})

	w.Header().Set("Cache-Control", "no-store")
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

	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(adminSessionResponse{
		Authenticated: authenticated,
		Username:      username,
	})
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
