// v1 仅驻留内存的 enrollment 与 Relay WebSocket 服务。
//
// 设备端接口刻意限制为 enrollment 和 v1 认证 Relay 连接；
// 已删除的 control 路由不属于当前线协议契约。

package relay

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
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
	config            Config
	hub               *hub
	upgrader          websocket.Upgrader
	enrolledDevices   map[string]*EnrolledDevice
	revokedDevices    map[string]struct{}
	proofNonces       map[string]map[string]time.Time
	devicesMutex      sync.Mutex
	adminUser         string
	adminPasswordHash [sha256.Size]byte
	adminConfigured   bool
	sessions          map[string]time.Time
	authMutex         sync.Mutex
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

// relayErrorCode 使用与 Dart NetworkErrorCode 对齐的稳定错误编号。
type relayErrorCode uint32

const (
	// relayErrorUnspecified 表示未分类的 Relay 错误。
	relayErrorUnspecified relayErrorCode = 0
	// relayErrorInvalidArgument 表示请求参数不符合协议边界。
	relayErrorInvalidArgument relayErrorCode = 1
	// relayErrorAuthenticationFailed 表示身份或管理员认证失败。
	relayErrorAuthenticationFailed relayErrorCode = 4
	// relayErrorProtocolError 表示协议版本或帧格式不受支持。
	relayErrorProtocolError relayErrorCode = 9
	// relayErrorRelayError 表示 Relay 内部服务错误。
	relayErrorRelayError relayErrorCode = 10
)

// networkErrorResponse 是 Relay HTTP API 的安全错误响应结构。
type networkErrorResponse struct {
	Code      relayErrorCode `json:"code"`
	Message   string         `json:"message"`
	Operation string         `json:"operation"`
	PeerID    string         `json:"peer_id,omitempty"`
}

// NewServer 根据给定配置创建仅驻留内存的 Relay 服务。
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
	if config.CredentialTTL <= 0 {
		config.CredentialTTL = 24 * time.Hour
	}
	if config.SessionTTL <= 0 {
		config.SessionTTL = 15 * time.Minute
	}
	if config.MaxConnections <= 0 {
		config.MaxConnections = 2048
	}

	adminPasswordHash := passwordDigest(config.CredentialKey, config.AdminPassword)
	adminConfigured := config.AdminUser != "" && len(config.AdminPassword) >= 12
	config.AdminPassword = ""

	return &Server{
		config:            config,
		hub:               newHub(config),
		upgrader:          websocket.Upgrader{},
		enrolledDevices:   make(map[string]*EnrolledDevice),
		revokedDevices:    make(map[string]struct{}),
		proofNonces:       make(map[string]map[string]time.Time),
		adminUser:         config.AdminUser,
		adminPasswordHash: adminPasswordHash,
		adminConfigured:   adminConfigured,
		sessions:          make(map[string]time.Time),
	}
}

// Close 停止 Relay hub，并释放活跃设备连接。
func (s *Server) Close() { s.hub.close() }

// RegisterRoutes 注册公开、管理端和 v1 设备端点。
func (s *Server) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /", s.dashboard)
	mux.Handle("GET /static/", s.staticFileHandler())
	mux.HandleFunc("GET /healthz", s.health)

	// 管理端认证路由。
	mux.HandleFunc("POST /api/login", s.loginHandler)
	mux.HandleFunc("POST /api/logout", s.logoutHandler)
	mux.HandleFunc("GET /api/auth-status", s.authStatusHandler)

	// 管理端受认证保护的路由。
	mux.HandleFunc("GET /api/stats", s.authMiddleware(s.apiStats))
	mux.HandleFunc("POST /api/token/rotate", s.authMiddleware(s.rotateToken))
	mux.HandleFunc("POST /api/devices/revoke", s.authMiddleware(s.revokeDevice))

	// v1 设备协议路由。
	mux.HandleFunc("POST /v1/devices/enroll", s.enroll)
	mux.HandleFunc("GET /v1/connect", s.connect)
}

// health 提供无需认证的存活检查端点。
func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}

// writeNetworkError 写入不泄露底层异常文本的稳定 JSON 错误。
func writeNetworkError(
	w http.ResponseWriter,
	status int,
	code relayErrorCode,
	message string,
	operation string,
	peerID string,
) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(networkErrorResponse{
		Code:      code,
		Message:   message,
		Operation: operation,
		PeerID:    peerID,
	})
}

// enroll 校验设备证明并签发 v1 Relay 凭据。
func (s *Server) enroll(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	var request enrollRequest
	if json.NewDecoder(r.Body).Decode(&request) != nil {
		writeNetworkError(
			w,
			http.StatusBadRequest,
			relayErrorInvalidArgument,
			"Enrollment request is invalid.",
			"enroll_relay",
			"",
		)
		return
	}
	if !s.validEnrollmentToken(request.EnrollmentToken) {
		writeNetworkError(
			w,
			http.StatusUnauthorized,
			relayErrorAuthenticationFailed,
			"Relay enrollment authentication failed.",
			"enroll_relay",
			request.DeviceID,
		)
		return
	}
	if request.DeviceID == "" || len(request.DeviceID) > 128 {
		writeNetworkError(
			w,
			http.StatusBadRequest,
			relayErrorInvalidArgument,
			"Device identity is invalid.",
			"enroll_relay",
			request.DeviceID,
		)
		return
	}
	if request.ProtocolVersion != 1 {
		writeNetworkError(
			w,
			http.StatusBadRequest,
			relayErrorProtocolError,
			"Relay protocol version is unsupported.",
			"enroll_relay",
			request.DeviceID,
		)
		return
	}
	if len(request.Platform) > 64 {
		writeNetworkError(
			w,
			http.StatusBadRequest,
			relayErrorInvalidArgument,
			"Device platform is invalid.",
			"enroll_relay",
			request.DeviceID,
		)
		return
	}
	publicKey, err := base64.RawURLEncoding.DecodeString(request.PublicKey)
	if err != nil || len(publicKey) != ed25519.PublicKeySize {
		writeNetworkError(
			w,
			http.StatusBadRequest,
			relayErrorInvalidArgument,
			"Device public key is invalid.",
			"enroll_relay",
			request.DeviceID,
		)
		return
	}
	credential, err := issueCredential(s.config.CredentialKey, request.DeviceID, publicKey, s.config.CredentialTTL)
	if err != nil {
		writeNetworkError(
			w,
			http.StatusInternalServerError,
			relayErrorRelayError,
			"Relay credential issuance failed.",
			"enroll_relay",
			request.DeviceID,
		)
		return
	}
	now := time.Now()
	s.replaceEnrollment(
		request.DeviceID,
		request.PublicKey,
		request.Platform,
		request.ProtocolVersion,
		now,
	)
	writeEnrollmentResponse(
		w,
		credential,
		now,
		s.config.CredentialTTL,
		request.ProtocolVersion,
	)
}

// replaceEnrollment 为一个设备轮换凭据和证明 nonce。
func (s *Server) replaceEnrollment(
	deviceID string,
	publicKey string,
	platform string,
	protocolVersion uint32,
	enrolledAt time.Time,
) {
	s.devicesMutex.Lock()
	s.enrolledDevices[deviceID] = &EnrolledDevice{
		DeviceID:        deviceID,
		PublicKey:       publicKey,
		Platform:        platform,
		ProtocolVersion: protocolVersion,
		EnrolledAt:      enrolledAt,
	}
	delete(s.revokedDevices, deviceID)
	delete(s.proofNonces, deviceID)
	s.devicesMutex.Unlock()
	s.hub.disconnectDevice(deviceID)
}

// writeEnrollmentResponse 序列化成功的 enrollment 响应。
func writeEnrollmentResponse(
	w http.ResponseWriter,
	credential string,
	serverTime time.Time,
	ttl time.Duration,
	protocolVersion uint32,
) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(enrollResponse{
		Credential:      credential,
		ExpiresAt:       serverTime.Add(ttl).Unix(),
		ServerTime:      serverTime.Unix(),
		ProtocolVersion: protocolVersion,
	})
}

// rotateToken 轮换控制台使用的管理员凭据。
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

// revokeDevice 撤销已 enrollment 设备，并关闭其活跃会话。
func (s *Server) revokeDevice(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	var req struct {
		DeviceID string `json:"device_id"`
	}
	if json.NewDecoder(r.Body).Decode(&req) != nil || req.DeviceID == "" {
		writeNetworkError(
			w,
			http.StatusBadRequest,
			relayErrorInvalidArgument,
			"Device identity is invalid.",
			"revoke_device",
			req.DeviceID,
		)
		return
	}

	s.devicesMutex.Lock()
	delete(s.enrolledDevices, req.DeviceID)
	s.revokedDevices[req.DeviceID] = struct{}{}
	delete(s.proofNonces, req.DeviceID)
	s.devicesMutex.Unlock()

	s.hub.disconnectDevice(req.DeviceID)

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"device_id": req.DeviceID})
}

// authenticatedRequest 校验设备凭据并返回其 claims。
func (s *Server) authenticatedRequest(r *http.Request) (credentialClaims, []byte, bool) {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	claims, publicKey, err := verifyCredential(s.config.CredentialKey, token)
	if err != nil {
		return credentialClaims{}, nil, false
	}
	nonce := r.Header.Get("X-Relay-Nonce")
	nonceBytes, err := base64.RawURLEncoding.DecodeString(nonce)
	if err != nil || len(nonceBytes) != 32 {
		return credentialClaims{}, nil, false
	}
	signature := r.Header.Get("X-Relay-Signature")
	proofPayload := r.Method + "\n" + r.URL.Path + "\n" + nonce
	if err := verifyDeviceProof(publicKey, proofPayload, signature); err != nil {
		return credentialClaims{}, nil, false
	}
	s.devicesMutex.Lock()
	_, revoked := s.revokedDevices[claims.DeviceID]
	device, enrolled := s.enrolledDevices[claims.DeviceID]
	keyMatches := enrolled &&
		device.PublicKey == base64.RawURLEncoding.EncodeToString(publicKey)
	replayed := false
	if !revoked && keyMatches {
		replayed = s.consumeProofNonceLocked(
			claims.DeviceID,
			nonce,
			time.Unix(claims.ExpiresAt, 0),
		)
	}
	s.devicesMutex.Unlock()
	if revoked || !keyMatches || replayed {
		return credentialClaims{}, nil, false
	}
	return claims, publicKey, true
}

// consumeProofNonceLocked 校验并消费一次性 enrollment nonce。
func (s *Server) consumeProofNonceLocked(deviceID, nonce string, expiresAt time.Time) bool {
	now := time.Now()
	deviceNonces := s.proofNonces[deviceID]
	if deviceNonces == nil {
		deviceNonces = make(map[string]time.Time)
		s.proofNonces[deviceID] = deviceNonces
	}
	for value, expiry := range deviceNonces {
		if now.After(expiry) {
			delete(deviceNonces, value)
		}
	}
	if _, exists := deviceNonces[nonce]; exists {
		return true
	}
	if len(deviceNonces) >= 128 {
		return true
	}
	deviceNonces[nonce] = expiresAt
	return false
}

// validEnrollmentToken 报告管理员 token 是否仍然有效。
func (s *Server) validEnrollmentToken(token string) bool {
	s.devicesMutex.Lock()
	expected := s.config.EnrollmentToken
	s.devicesMutex.Unlock()
	return token != "" && hmac.Equal([]byte(token), []byte(expected))
}

// connect 将已认证设备请求升级到 v1 WebSocket 路径。
func (s *Server) connect(w http.ResponseWriter, r *http.Request) {
	s.upgradeDevice(w, r)
}

// upgradeDevice 认证并注册一个设备 WebSocket 连接。
func (s *Server) upgradeDevice(w http.ResponseWriter, r *http.Request) {
	claims, _, ok := s.authenticatedRequest(r)
	if !ok {
		writeNetworkError(
			w,
			http.StatusUnauthorized,
			relayErrorAuthenticationFailed,
			"Relay device authentication failed.",
			"connect_relay",
			"",
		)
		return
	}
	connection, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	peer := &peer{
		deviceID: claims.DeviceID,
		socket:   connection,
		outbound: make(chan outboundFrame, 32),
		done:     make(chan struct{}),
	}
	if !s.hub.add(peer) {
		connection.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "connection limit"), time.Now().Add(time.Second))
		connection.Close()
		return
	}
	ready, _ := json.Marshal(controlFrame{
		Type:            "ready",
		DeviceID:        claims.DeviceID,
		Timestamp:       time.Now().UnixMilli(),
		ProtocolVersion: 1,
	})
	if !peer.enqueue(outboundFrame{websocket.TextMessage, ready}) {
		s.hub.remove(peer)
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
	done            chan struct{}
	once            sync.Once
	windowStartedAt time.Time
	framesInWindow  int
	lastSeen        time.Time
}

type session struct {
	sender    string
	receiver  string
	expiresAt time.Time
	accepted  bool
	completed bool
}

type controlFrame struct {
	Type            string `json:"type"`
	SessionID       string `json:"session_id,omitempty"`
	TargetID        string `json:"target_id,omitempty"`
	SenderID        string `json:"sender_id,omitempty"`
	DeviceID        string `json:"device_id,omitempty"`
	Payload         string `json:"payload,omitempty"`
	Timestamp       int64  `json:"timestamp,omitempty"`
	ProtocolVersion uint32 `json:"protocol_version,omitempty"`
	Online          *bool  `json:"online,omitempty"`
}

type hub struct {
	config   Config
	mutex    sync.Mutex
	peers    map[string]*peer
	sessions map[string]session
	stop     chan struct{}
}

// newHub 创建有界内存设备路由 hub。
func newHub(config Config) *hub {
	h := &hub{config: config, peers: map[string]*peer{}, sessions: map[string]session{}, stop: make(chan struct{})}
	go h.prune()
	return h
}

// close 停止全部 hub worker，并关闭每个已连接对端。
func (h *hub) close() {
	close(h.stop)
	h.mutex.Lock()
	peers := make([]*peer, 0, len(h.peers))
	for _, value := range h.peers {
		peers = append(peers, value)
	}
	h.peers = map[string]*peer{}
	h.sessions = map[string]session{}
	h.mutex.Unlock()
	for _, peer := range peers {
		closePeer(peer)
	}
}

// add 注册对端，除非 hub 已经关闭。
func (h *hub) add(peer *peer) bool {
	peer.lastSeen = time.Now()
	h.mutex.Lock()
	previous := h.peers[peer.deviceID]
	if previous == nil && len(h.peers) >= h.config.MaxConnections {
		h.mutex.Unlock()
		return false
	}
	h.peers[peer.deviceID] = peer
	h.mutex.Unlock()
	if previous != nil {
		closePeer(previous)
	}
	go h.write(peer)
	go h.read(peer)
	return true
}

// remove 从 hub 注销对端。
func (h *hub) remove(peer *peer) {
	h.mutex.Lock()
	if h.peers[peer.deviceID] == peer {
		delete(h.peers, peer.deviceID)
	}
	h.mutex.Unlock()
	closePeer(peer)
}

// closePeer 恰好关闭一个对端一次。
func closePeer(peer *peer) {
	peer.once.Do(func() {
		close(peer.done)
		peer.socket.Close()
	})
}

// disconnectDevice 关闭属于指定设备标识的全部会话。
func (h *hub) disconnectDevice(deviceID string) {
	h.mutex.Lock()
	peer := h.peers[deviceID]
	if peer != nil {
		delete(h.peers, deviceID)
	}
	for sessionID, current := range h.sessions {
		if current.sender == deviceID || current.receiver == deviceID {
			delete(h.sessions, sessionID)
		}
	}
	h.mutex.Unlock()
	if peer != nil {
		closePeer(peer)
	}
}

// write 将对端队列中的帧转发到其 WebSocket 连接。
func (h *hub) write(peer *peer) {
	defer h.remove(peer)
	for {
		select {
		case <-peer.done:
			return
		case frame := <-peer.outbound:
			peer.socket.SetWriteDeadline(time.Now().Add(15 * time.Second))
			if err := peer.socket.WriteMessage(frame.messageType, frame.data); err != nil {
				return
			}
		}
	}
}

// read 校验传入帧，并将其路由到目标对端。
func (h *hub) read(peer *peer) {
	defer h.remove(peer)
	peer.socket.SetReadLimit(maxBinaryFrameBytes)
	for {
		kind, data, err := peer.socket.ReadMessage()
		if err != nil {
			return
		}
		h.mutex.Lock()
		peer.lastSeen = time.Now()
		h.mutex.Unlock()
		if kind == websocket.TextMessage {
			h.routeControl(peer, data)
		} else if kind == websocket.BinaryMessage {
			h.routeBinary(peer, data)
		} else {
			return
		}
	}
}

// enqueue 向对端队列加入一个有界出站帧。
func (p *peer) enqueue(frame outboundFrame) bool {
	select {
	case <-p.done:
		return false
	default:
	}
	select {
	case <-p.done:
		return false
	case p.outbound <- frame:
		return true
	default:
		return false
	}
}

// routeControl 校验并转发一个 JSON 控制信封。
func (h *hub) routeControl(sender *peer, data []byte) {
	if !sender.allowFrame() || len(data) > maxControlFrameBytes {
		return
	}
	h.mutex.Lock()
	isCurrent := h.peers[sender.deviceID] == sender
	h.mutex.Unlock()
	if !isCurrent {
		return
	}
	var frame controlFrame
	if json.Unmarshal(data, &frame) != nil {
		return
	}

	// 处理 heartbeat ping。
	if frame.Type == "heartbeat" {
		resp, _ := json.Marshal(controlFrame{
			Type:      "heartbeat_ack",
			Timestamp: time.Now().UnixMilli(),
		})
		if !sender.enqueue(outboundFrame{websocket.TextMessage, resp}) {
			go sender.socket.Close()
		}
		return
	}

	// 处理对端查询。
	if frame.Type == "lookup" {
		h.mutex.Lock()
		_, isOnline := h.peers[frame.TargetID]
		h.mutex.Unlock()

		resp, _ := json.Marshal(controlFrame{
			Type:     "lookup_response",
			TargetID: frame.TargetID,
			Online:   &isOnline,
		})
		if !sender.enqueue(outboundFrame{websocket.TextMessage, resp}) {
			go sender.socket.Close()
		}
		return
	}

	switch frame.Type {
	case "offer", "accept", "resume", "complete", "complete_ack", "cancel":
	default:
		return
	}
	if len(frame.SessionID) != 32 {
		return
	}
	if frame.SessionID != strings.ToLower(frame.SessionID) {
		return
	}
	if _, err := hex.DecodeString(frame.SessionID); err != nil {
		return
	}

	h.mutex.Lock()
	defer h.mutex.Unlock()
	if frame.Type == "offer" {
		if frame.TargetID == "" ||
			frame.TargetID == sender.deviceID ||
			frame.Payload == "" ||
			h.peers[frame.TargetID] == nil {
			return
		}
		if _, err := base64.RawURLEncoding.DecodeString(frame.Payload); err != nil {
			return
		}
		if _, exists := h.sessions[frame.SessionID]; exists {
			return
		}
		h.sessions[frame.SessionID] = session{
			sender:    sender.deviceID,
			receiver:  frame.TargetID,
			expiresAt: time.Now().Add(h.config.SessionTTL),
		}
	} else {
		current, exists := h.sessions[frame.SessionID]
		if !exists ||
			time.Now().After(current.expiresAt) ||
			(current.sender != sender.deviceID && current.receiver != sender.deviceID) {
			if exists && time.Now().After(current.expiresAt) {
				delete(h.sessions, frame.SessionID)
			}
			return
		}
		switch frame.Type {
		case "accept":
			if current.receiver != sender.deviceID || current.accepted || current.completed {
				return
			}
			current.accepted = true
		case "resume":
			if current.receiver != sender.deviceID || current.completed {
				return
			}
			current.accepted = true
		case "complete":
			if current.sender != sender.deviceID || !current.accepted || current.completed {
				return
			}
			current.completed = true
		case "complete_ack":
			if current.receiver != sender.deviceID || !current.completed {
				return
			}
		case "cancel":
			// 任一参与方都可以取消会话。
		default:
			return
		}
		current.expiresAt = time.Now().Add(h.config.SessionTTL)
		h.sessions[frame.SessionID] = current
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
		forwarded, err := json.Marshal(controlFrame{
			Type:      frame.Type,
			SessionID: frame.SessionID,
			SenderID:  sender.deviceID,
			Payload:   frame.Payload,
		})
		if err != nil || !target.enqueue(outboundFrame{websocket.TextMessage, forwarded}) {
			go target.socket.Close()
		}
	}
	if frame.Type == "cancel" || frame.Type == "complete_ack" {
		delete(h.sessions, frame.SessionID)
	}
}

// routeBinary 校验并转发一个不透明加密载荷。
func (h *hub) routeBinary(sender *peer, data []byte) {
	if !sender.allowFrame() ||
		len(data) < 25 ||
		len(data) > maxBinaryFrameBytes ||
		data[0] != 0x10 {
		return
	}
	h.mutex.Lock()
	isCurrent := h.peers[sender.deviceID] == sender
	h.mutex.Unlock()
	if !isCurrent {
		return
	}
	sessionID := hex.EncodeToString(data[1:17])
	h.mutex.Lock()
	current, ok := h.sessions[sessionID]
	if !ok ||
		current.sender != sender.deviceID ||
		!current.accepted ||
		current.completed ||
		time.Now().After(current.expiresAt) {
		if ok && time.Now().After(current.expiresAt) {
			delete(h.sessions, sessionID)
		}
		h.mutex.Unlock()
		return
	}
	current.expiresAt = time.Now().Add(h.config.SessionTTL)
	h.sessions[sessionID] = current
	target := h.peers[current.receiver]
	h.mutex.Unlock()
	if target == nil {
		return
	}
	copyData := append([]byte(nil), data...)
	if !target.enqueue(outboundFrame{websocket.BinaryMessage, copyData}) {
		go target.socket.Close()
	}
}

// allowFrame 执行每个对端的帧速率限制。
func (p *peer) allowFrame() bool {
	now := time.Now()
	if now.Sub(p.windowStartedAt) >= time.Second {
		p.windowStartedAt = now
		p.framesInWindow = 0
	}
	p.framesInWindow++
	return p.framesInWindow <= 256
}

// prune 移除过期的内存会话记录。
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

// createSession 保存短期管理员控制台会话。
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

// destroySession 移除管理员控制台会话。
func (s *Server) destroySession(token string) {
	s.authMutex.Lock()
	defer s.authMutex.Unlock()
	delete(s.sessions, token)
}

// isAuthorized 校验管理员 cookie 或 bearer token。
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

// authMiddleware 使用管理员认证保护 HTTP handler。
func (s *Server) authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.isAuthorized(r) {
			writeNetworkError(
				w,
				http.StatusUnauthorized,
				relayErrorAuthenticationFailed,
				"Administrator authentication failed.",
				"admin_auth",
				"",
			)
			return
		}
		next(w, r)
	}
}

// loginHandler 认证控制台管理员。
func (s *Server) loginHandler(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if json.NewDecoder(r.Body).Decode(&req) != nil {
		writeNetworkError(
			w,
			http.StatusBadRequest,
			relayErrorInvalidArgument,
			"Login request is invalid.",
			"login",
			"",
		)
		return
	}

	s.authMutex.Lock()
	candidatePasswordHash := passwordDigest(s.config.CredentialKey, req.Password)
	valid := s.adminConfigured &&
		hmac.Equal([]byte(req.Username), []byte(s.adminUser)) &&
		hmac.Equal(candidatePasswordHash[:], s.adminPasswordHash[:])
	username := s.adminUser
	s.authMutex.Unlock()

	if !valid {
		writeNetworkError(
			w,
			http.StatusUnauthorized,
			relayErrorAuthenticationFailed,
			"Administrator authentication failed.",
			"login",
			"",
		)
		return
	}

	token := s.createSession()
	http.SetCookie(w, &http.Cookie{
		Name:     "relay_session",
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		Secure:   requestUsesTLS(r),
		SameSite: http.SameSiteLaxMode,
		MaxAge:   86400,
	})

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"username": username})
}

// logoutHandler 使控制台管理员会话 cookie 失效。
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
	w.WriteHeader(http.StatusNoContent)
}

// authStatusHandler 报告当前管理员认证状态。
func (s *Server) authStatusHandler(w http.ResponseWriter, r *http.Request) {
	authed := s.isAuthorized(r)
	s.authMutex.Lock()
	username := s.adminUser
	s.authMutex.Unlock()
	if !authed {
		username = ""
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"authenticated": authed,
		"username":      username,
	})
}

// passwordDigest 派生配置的管理员密码摘要。
func passwordDigest(key []byte, password string) [sha256.Size]byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(password))
	var digest [sha256.Size]byte
	copy(digest[:], mac.Sum(nil))
	return digest
}

// requestUsesTLS 报告请求是否通过 TLS 到达。
func requestUsesTLS(r *http.Request) bool {
	return r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")
}
