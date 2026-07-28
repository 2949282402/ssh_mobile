package relay

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type EnrolledDevice struct {
	DeviceID        string    `json:"device_id"`
	PublicKey       string    `json:"public_key"`
	Platform        string    `json:"platform"`
	ProtocolVersion uint32    `json:"protocol_version"`
	EnrolledAt      time.Time `json:"enrolled_at"`
}

type Server struct {
	config             Config
	hub                *hub
	upgrader           websocket.Upgrader
	enrolledDevices    map[string]*EnrolledDevice
	devicesMutex       sync.Mutex
	adminUser          string
	adminPassword      string
	mustChangePassword bool
	sessions           map[string]time.Time
	authMutex          sync.Mutex
}

type registrationRequest struct {
	DeviceID        string `json:"device_id"`
	PublicKey       string `json:"public_key"`
	EnrollmentToken string `json:"enrollment_token"`
}

type registrationResponse struct {
	Credential string `json:"credential"`
	ExpiresAt  int64  `json:"expires_at"`
}

type enrollRequest struct {
	DeviceID        string `json:"device_id"`
	PublicKey       string `json:"public_key"`
	EnrollmentToken string `json:"enrollment_token"`
	ProtocolVersion uint32 `json:"protocol_version"`
	Platform        string `json:"platform"`
}

type enrollResponse struct {
	Credential      string `json:"credential"`
	ExpiresAt       int64  `json:"expires_at"`
	ServerTime      int64  `json:"server_time"`
	ProtocolVersion uint32 `json:"protocol_version"`
}

func NewServer(config Config) *Server {
	if config.Address == "" {
		config.Address = ":8080"
	}
	if config.EnrollmentToken == "" {
		config.EnrollmentToken = hex.EncodeToString(randomBytes(16))
	}
	if len(config.CredentialKey) == 0 {
		config.CredentialKey = randomBytes(32)
	}

	adminUser := config.AdminUser
	if adminUser == "" {
		adminUser = "hejulian"
	}
	adminPassword := config.AdminPassword
	if adminPassword == "" {
		adminPassword = "hejulian"
	}
	mustChange := adminPassword == "hejulian"

	return &Server{
		config:             config,
		hub:                newHub(config),
		upgrader:           websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return false }},
		enrolledDevices:    make(map[string]*EnrolledDevice),
		adminUser:          adminUser,
		adminPassword:      adminPassword,
		mustChangePassword: mustChange,
		sessions:           make(map[string]time.Time),
	}
}

func (s *Server) Close() { s.hub.close() }

func (s *Server) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /", s.dashboard)
	mux.Handle("GET /static/", s.staticFileHandler())
	mux.HandleFunc("GET /healthz", s.health)

	// Admin Auth routes
	mux.HandleFunc("POST /api/login", s.loginHandler)
	mux.HandleFunc("POST /api/logout", s.logoutHandler)
	mux.HandleFunc("GET /api/auth-status", s.authStatusHandler)
	mux.HandleFunc("POST /api/change-password", s.changePasswordHandler)

	// Admin Protected routes
	mux.HandleFunc("GET /api/stats", s.authMiddleware(s.apiStats))
	mux.HandleFunc("POST /api/token/rotate", s.authMiddleware(s.rotateToken))
	mux.HandleFunc("POST /api/devices/revoke", s.authMiddleware(s.revokeDevice))

	// Device protocol routes
	mux.HandleFunc("POST /v1/devices/register", s.register)
	mux.HandleFunc("POST /v1/devices/enroll", s.enroll)
	mux.HandleFunc("GET /v1/connect", s.connect)
	mux.HandleFunc("GET /v1/control", s.control)
}

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) register(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	var request registrationRequest
	if json.NewDecoder(r.Body).Decode(&request) != nil || request.EnrollmentToken != s.config.EnrollmentToken || request.DeviceID == "" || len(request.DeviceID) > 128 {
		http.Error(w, "invalid registration", http.StatusUnauthorized)
		return
	}
	publicKey, err := base64.RawURLEncoding.DecodeString(request.PublicKey)
	if err != nil || len(publicKey) != ed25519.PublicKeySize {
		http.Error(w, "invalid public key", http.StatusBadRequest)
		return
	}
	credential, err := issueCredential(s.config.CredentialKey, request.DeviceID, publicKey, s.config.CredentialTTL)
	if err != nil {
		http.Error(w, "credential issuance failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(registrationResponse{credential, time.Now().Add(s.config.CredentialTTL).Unix()})
}

func (s *Server) enroll(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	var request enrollRequest
	if json.NewDecoder(r.Body).Decode(&request) != nil || request.EnrollmentToken != s.config.EnrollmentToken || request.DeviceID == "" || len(request.DeviceID) > 128 {
		http.Error(w, "invalid enrollment request", http.StatusUnauthorized)
		return
	}
	if request.ProtocolVersion == 0 {
		request.ProtocolVersion = 1
	}
	publicKey, err := base64.RawURLEncoding.DecodeString(request.PublicKey)
	if err != nil || len(publicKey) != ed25519.PublicKeySize {
		http.Error(w, "invalid public key", http.StatusBadRequest)
		return
	}
	credential, err := issueCredential(s.config.CredentialKey, request.DeviceID, publicKey, s.config.CredentialTTL)
	if err != nil {
		http.Error(w, "credential issuance failed", http.StatusInternalServerError)
		return
	}
	now := time.Now()
	s.devicesMutex.Lock()
	s.enrolledDevices[request.DeviceID] = &EnrolledDevice{
		DeviceID:        request.DeviceID,
		PublicKey:       request.PublicKey,
		Platform:        request.Platform,
		ProtocolVersion: request.ProtocolVersion,
		EnrolledAt:      now,
	}
	s.devicesMutex.Unlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(enrollResponse{
		Credential:      credential,
		ExpiresAt:       now.Add(s.config.CredentialTTL).Unix(),
		ServerTime:      now.Unix(),
		ProtocolVersion: 1,
	})
}

func (s *Server) rotateToken(w http.ResponseWriter, _ *http.Request) {
	newToken := hex.EncodeToString(randomBytes(16))
	s.devicesMutex.Lock()
	s.config.EnrollmentToken = newToken
	s.devicesMutex.Unlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"enrollment_token": newToken,
	})
}

func (s *Server) revokeDevice(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()
	var req struct {
		DeviceID string `json:"device_id"`
	}
	if json.NewDecoder(r.Body).Decode(&req) != nil || req.DeviceID == "" {
		http.Error(w, "invalid request", http.StatusBadRequest)
		return
	}

	s.devicesMutex.Lock()
	delete(s.enrolledDevices, req.DeviceID)
	s.devicesMutex.Unlock()

	s.hub.mutex.Lock()
	p := s.hub.peers[req.DeviceID]
	if p != nil && p.socket != nil {
		go p.socket.Close()
	}
	s.hub.mutex.Unlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]bool{"success": true})
}

func (s *Server) authenticatedRequest(r *http.Request) (credentialClaims, []byte, bool) {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	claims, publicKey, err := verifyCredential(s.config.CredentialKey, token)
	if err != nil {
		return credentialClaims{}, nil, false
	}
	if err := verifyDeviceProof(publicKey, r.Header.Get("X-Relay-Nonce"), r.Header.Get("X-Relay-Signature")); err != nil {
		return credentialClaims{}, nil, false
	}
	return claims, publicKey, true
}

func (s *Server) connect(w http.ResponseWriter, r *http.Request) {
	claims, _, ok := s.authenticatedRequest(r)
	if !ok {
		http.Error(w, "authentication failed", http.StatusUnauthorized)
		return
	}
	connection, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	if !s.hub.add(&peer{deviceID: claims.DeviceID, socket: connection, outbound: make(chan outboundFrame, 32)}) {
		connection.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "connection limit"), time.Now().Add(time.Second))
		connection.Close()
	}
}

func (s *Server) control(w http.ResponseWriter, r *http.Request) {
	claims, _, ok := s.authenticatedRequest(r)
	if !ok {
		http.Error(w, "authentication failed", http.StatusUnauthorized)
		return
	}
	connection, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	if !s.hub.add(&peer{deviceID: claims.DeviceID, socket: connection, outbound: make(chan outboundFrame, 32)}) {
		connection.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "connection limit"), time.Now().Add(time.Second))
		connection.Close()
	}
}

type outboundFrame struct {
	messageType int
	data        []byte
}

type peer struct {
	deviceID        string
	socket          *websocket.Conn
	outbound        chan outboundFrame
	once            sync.Once
	windowStartedAt time.Time
	framesInWindow  int
	lastSeen        time.Time
}

type session struct {
	sender    string
	receiver  string
	expiresAt time.Time
}

type controlFrame struct {
	Type      string `json:"type"`
	SessionID string `json:"session_id,omitempty"`
	TargetID  string `json:"target_id,omitempty"`
	Payload   string `json:"payload,omitempty"`
	Timestamp int64  `json:"timestamp,omitempty"`
	Online    bool   `json:"online,omitempty"`
}

type hub struct {
	config   Config
	mutex    sync.Mutex
	peers    map[string]*peer
	sessions map[string]session
	stop     chan struct{}
}

func newHub(config Config) *hub {
	h := &hub{config: config, peers: map[string]*peer{}, sessions: map[string]session{}, stop: make(chan struct{})}
	go h.prune()
	return h
}

func (h *hub) close() {
	close(h.stop)
	h.mutex.Lock()
	defer h.mutex.Unlock()
	for _, peer := range h.peers {
		peer.socket.Close()
	}
	h.peers = map[string]*peer{}
	h.sessions = map[string]session{}
}

func (h *hub) add(peer *peer) bool {
	peer.lastSeen = time.Now()
	h.mutex.Lock()
	if len(h.peers) >= h.config.MaxConnections {
		h.mutex.Unlock()
		return false
	}
	previous := h.peers[peer.deviceID]
	h.peers[peer.deviceID] = peer
	h.mutex.Unlock()
	if previous != nil {
		previous.socket.Close()
	}
	go h.write(peer)
	go h.read(peer)
	return true
}

func (h *hub) remove(peer *peer) {
	peer.once.Do(func() {
		h.mutex.Lock()
		if h.peers[peer.deviceID] == peer {
			delete(h.peers, peer.deviceID)
		}
		h.mutex.Unlock()
		peer.socket.Close()
	})
}

func (h *hub) write(peer *peer) {
	defer h.remove(peer)
	for frame := range peer.outbound {
		peer.socket.SetWriteDeadline(time.Now().Add(15 * time.Second))
		if err := peer.socket.WriteMessage(frame.messageType, frame.data); err != nil {
			return
		}
	}
}

func (h *hub) read(peer *peer) {
	defer h.remove(peer)
	peer.socket.SetReadLimit(maxBinaryFrameBytes)
	for {
		kind, data, err := peer.socket.ReadMessage()
		if err != nil {
			return
		}
		peer.lastSeen = time.Now()
		if kind == websocket.TextMessage {
			h.routeControl(peer, data)
		} else if kind == websocket.BinaryMessage {
			h.routeBinary(peer, data)
		} else {
			return
		}
	}
}

func (h *hub) routeControl(sender *peer, data []byte) {
	if !sender.allowFrame() || len(data) > maxControlFrameBytes {
		return
	}
	var frame controlFrame
	if json.Unmarshal(data, &frame) != nil {
		return
	}

	// Handle heartbeat ping
	if frame.Type == "heartbeat" {
		resp, _ := json.Marshal(controlFrame{
			Type:      "heartbeat_ack",
			Timestamp: time.Now().UnixMilli(),
		})
		select {
		case sender.outbound <- outboundFrame{websocket.TextMessage, resp}:
		default:
		}
		return
	}

	// Handle peer lookup
	if frame.Type == "lookup" {
		h.mutex.Lock()
		_, isOnline := h.peers[frame.TargetID]
		h.mutex.Unlock()

		resp, _ := json.Marshal(controlFrame{
			Type:     "lookup_response",
			TargetID: frame.TargetID,
			Online:   isOnline,
		})
		select {
		case sender.outbound <- outboundFrame{websocket.TextMessage, resp}:
		default:
		}
		return
	}

	if len(frame.SessionID) != 32 {
		return
	}
	if _, err := hex.DecodeString(frame.SessionID); err != nil {
		return
	}

	h.mutex.Lock()
	defer h.mutex.Unlock()
	if frame.Type == "offer" {
		if frame.TargetID == "" || frame.TargetID == sender.deviceID || h.peers[frame.TargetID] == nil {
			return
		}
		h.sessions[frame.SessionID] = session{sender.deviceID, frame.TargetID, time.Now().Add(h.config.SessionTTL)}
	} else {
		current, exists := h.sessions[frame.SessionID]
		if !exists || (current.sender != sender.deviceID && current.receiver != sender.deviceID) {
			return
		}
	}
	current, ok := h.sessions[frame.SessionID]
	if !ok {
		return
	}
	targetID := current.receiver
	if sender.deviceID == current.receiver {
		targetID = current.sender
	}
	target := h.peers[targetID]
	if target != nil {
		select {
		case target.outbound <- outboundFrame{websocket.TextMessage, data}:
		default:
			go target.socket.Close()
		}
	}
	if frame.Type == "cancel" {
		delete(h.sessions, frame.SessionID)
	}
}

func (h *hub) routeBinary(sender *peer, data []byte) {
	if !sender.allowFrame() || len(data) < 25 || len(data) > maxBinaryFrameBytes {
		return
	}
	sessionID := hex.EncodeToString(data[1:17])
	h.mutex.Lock()
	current, ok := h.sessions[sessionID]
	if !ok || (current.sender != sender.deviceID && current.receiver != sender.deviceID) || time.Now().After(current.expiresAt) {
		h.mutex.Unlock()
		return
	}
	targetID := current.receiver
	if sender.deviceID == current.receiver {
		targetID = current.sender
	}
	target := h.peers[targetID]
	h.mutex.Unlock()
	if target == nil {
		return
	}
	copyData := append([]byte(nil), data...)
	select {
	case target.outbound <- outboundFrame{websocket.BinaryMessage, copyData}:
	default:
		go target.socket.Close()
	}
}

func (p *peer) allowFrame() bool {
	now := time.Now()
	if now.Sub(p.windowStartedAt) >= time.Second {
		p.windowStartedAt = now
		p.framesInWindow = 0
	}
	p.framesInWindow++
	return p.framesInWindow <= 256
}

func (h *hub) prune() {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-h.stop:
			return
		case now := <-ticker.C:
			h.mutex.Lock()
			for id, value := range h.sessions {
				if now.After(value.expiresAt) {
					delete(h.sessions, id)
				}
			}
			h.mutex.Unlock()
		}
	}
}

func (s *Server) createSession() string {
	token := hex.EncodeToString(randomBytes(32))
	s.authMutex.Lock()
	defer s.authMutex.Unlock()
	now := time.Now()
	for t, exp := range s.sessions {
		if now.After(exp) {
			delete(s.sessions, t)
		}
	}
	s.sessions[token] = now.Add(24 * time.Hour)
	return token
}

func (s *Server) destroySession(token string) {
	s.authMutex.Lock()
	defer s.authMutex.Unlock()
	delete(s.sessions, token)
}

func (s *Server) isAuthorized(r *http.Request) bool {
	var token string
	if cookie, err := r.Cookie("relay_session"); err == nil {
		token = cookie.Value
	} else {
		token = strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	}
	if token == "" {
		return false
	}
	s.authMutex.Lock()
	defer s.authMutex.Unlock()
	exp, found := s.sessions[token]
	if !found || time.Now().After(exp) {
		if found {
			delete(s.sessions, token)
		}
		return false
	}
	return true
}

func (s *Server) authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.isAuthorized(r) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			json.NewEncoder(w).Encode(map[string]string{"error": "unauthorized"})
			return
		}
		s.authMutex.Lock()
		mustChange := s.mustChangePassword
		s.authMutex.Unlock()

		if mustChange {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusForbidden)
			json.NewEncoder(w).Encode(map[string]interface{}{
				"error":                "must_change_password",
				"must_change_password": true,
			})
			return
		}
		next(w, r)
	}
}

func (s *Server) loginHandler(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if json.NewDecoder(r.Body).Decode(&req) != nil {
		http.Error(w, "invalid login payload", http.StatusBadRequest)
		return
	}

	s.authMutex.Lock()
	valid := req.Username == s.adminUser && req.Password == s.adminPassword
	mustChange := s.mustChangePassword
	username := s.adminUser
	s.authMutex.Unlock()

	if !valid {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		json.NewEncoder(w).Encode(map[string]string{"error": "账号或密码错误"})
		return
	}

	token := s.createSession()
	http.SetCookie(w, &http.Cookie{
		Name:     "relay_session",
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   86400,
	})

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success":              true,
		"must_change_password": mustChange,
		"username":             username,
		"token":                token,
	})
}

func (s *Server) logoutHandler(w http.ResponseWriter, r *http.Request) {
	var token string
	if cookie, err := r.Cookie("relay_session"); err == nil {
		token = cookie.Value
	}
	if token != "" {
		s.destroySession(token)
	}
	http.SetCookie(w, &http.Cookie{
		Name:     "relay_session",
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		MaxAge:   -1,
	})
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]bool{"success": true})
}

func (s *Server) authStatusHandler(w http.ResponseWriter, r *http.Request) {
	authed := s.isAuthorized(r)
	s.authMutex.Lock()
	mustChange := s.mustChangePassword
	username := s.adminUser
	s.authMutex.Unlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"authenticated":        authed,
		"must_change_password": mustChange,
		"username":             username,
	})
}

func (s *Server) changePasswordHandler(w http.ResponseWriter, r *http.Request) {
	if !s.isAuthorized(r) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		json.NewEncoder(w).Encode(map[string]string{"error": "unauthorized"})
		return
	}

	defer r.Body.Close()
	var req struct {
		OldPassword string `json:"old_password"`
		NewPassword string `json:"new_password"`
	}
	if json.NewDecoder(r.Body).Decode(&req) != nil {
		http.Error(w, "invalid payload", http.StatusBadRequest)
		return
	}

	s.authMutex.Lock()
	defer s.authMutex.Unlock()

	if req.OldPassword != s.adminPassword {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "旧密码输入不正确"})
		return
	}

	if len(req.NewPassword) < 6 {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "新密码长度不能少于 6 位"})
		return
	}

	if req.NewPassword == s.adminPassword {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "新密码不能与原初始密码相同"})
		return
	}

	s.adminPassword = req.NewPassword
	s.mustChangePassword = false

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]bool{"success": true})
}
