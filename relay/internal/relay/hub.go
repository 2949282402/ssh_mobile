package relay

import (
	"encoding/hex"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

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
	config           Config
	mutex            sync.Mutex
	peers            map[string]*peer
	transferSessions map[string]session
	stop             chan struct{}
}

func newHub(config Config) *hub {
	h := &hub{config: config, peers: map[string]*peer{}, transferSessions: map[string]session{}, stop: make(chan struct{})}
	go h.prune()
	return h
}

func (h *hub) close() {
	close(h.stop)
	h.mutex.Lock()
	peers := make([]*peer, 0, len(h.peers))
	for _, value := range h.peers {
		peers = append(peers, value)
	}
	h.peers = map[string]*peer{}
	h.transferSessions = map[string]session{}
	h.mutex.Unlock()
	for _, peer := range peers {
		closePeer(peer)
	}
}
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

func (h *hub) remove(peer *peer) {
	h.mutex.Lock()
	if h.peers[peer.deviceID] == peer {
		delete(h.peers, peer.deviceID)
	}
	h.mutex.Unlock()
	closePeer(peer)
}

func closePeer(peer *peer) {
	peer.once.Do(func() {
		close(peer.done)
		_ = peer.socket.Close()
	})
}

func (h *hub) disconnectDevice(deviceID string) {
	h.mutex.Lock()
	peer := h.peers[deviceID]
	if peer != nil {
		delete(h.peers, deviceID)
	}
	for sessionID, current := range h.transferSessions {
		if current.sender == deviceID || current.receiver == deviceID {
			delete(h.transferSessions, sessionID)
		}
	}
	h.mutex.Unlock()
	if peer != nil {
		closePeer(peer)
	}
}

func (h *hub) write(peer *peer) {
	defer h.remove(peer)
	for {
		select {
		case <-peer.done:
			return
		case frame := <-peer.outbound:
			_ = peer.socket.SetWriteDeadline(time.Now().Add(15 * time.Second))
			if err := peer.socket.WriteMessage(frame.messageType, frame.data); err != nil {
				return
			}
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

func (h *hub) routeBinary(sender *peer, data []byte) {
	if !sender.allowFrame() || len(data) < 25 || len(data) > maxBinaryFrameBytes || data[0] != 0x10 {
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
	current, ok := h.transferSessions[sessionID]
	if !ok || current.sender != sender.deviceID || !current.accepted || current.completed || time.Now().After(current.expiresAt) {
		if ok && time.Now().After(current.expiresAt) {
			delete(h.transferSessions, sessionID)
		}
		h.mutex.Unlock()
		return
	}
	current.expiresAt = time.Now().Add(h.config.SessionTTL)
	h.transferSessions[sessionID] = current
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
			for id, value := range h.transferSessions {
				if now.After(value.expiresAt) {
					delete(h.transferSessions, id)
				}
			}
			h.mutex.Unlock()
		}
	}
}
