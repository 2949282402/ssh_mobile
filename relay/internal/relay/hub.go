package relay

import (
	"context"
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
	deviceID           string
	socket             *websocket.Conn
	outbound           chan outboundFrame
	done               chan struct{}
	once               sync.Once
	stateMutex         sync.Mutex
	pendingFrames      int
	pendingBytes       int64
	maxPendingFrames   int
	maxPendingBytes    int64
	maxFramesPerSecond int
	maxBytesPerSecond  int64
	windowStartedAt    time.Time
	framesInWindow     int
	bytesInWindow      int64
	lastSeen           time.Time
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

// presenceStore reports device connection state to the shared presence layer.
type presenceStore interface {
	SetPresence(ctx context.Context, deviceID string, p Presence, ttl time.Duration) error
	DeletePresence(ctx context.Context, deviceID string) error
}

type hub struct {
	config           Config
	mutex            sync.Mutex
	peers            map[string]*peer
	transferSessions map[string]session
	presence         presenceStore
	instanceID       string
	presenceTTL      time.Duration
	stop             chan struct{}
	closeOnce        sync.Once
	waitGroup        sync.WaitGroup
	closed           bool
}

func newHub(config Config) *hub {
	config = withConfigDefaults(config)
	h := &hub{
		config:           config,
		peers:            map[string]*peer{},
		transferSessions: map[string]session{},
		instanceID:       config.InstanceID,
		presenceTTL:      config.PresenceTTL,
		stop:             make(chan struct{}),
	}
	h.waitGroup.Add(1)
	go func() {
		defer h.waitGroup.Done()
		h.prune()
	}()
	return h
}

// presenceFor builds the shared presence value for a connected peer.
func (h *hub) presenceFor(peer *peer) Presence {
	value := Presence{InstanceID: h.instanceID, LastSeen: time.Now()}
	if peer.socket != nil && peer.socket.RemoteAddr() != nil {
		value.RemoteAddr = peer.socket.RemoteAddr().String()
	}
	return value
}

// hubCloseTimeout bounds the peer/pruner convergence wait during close. Peer
// sockets are closed before waiting, so this normally returns immediately; the
// bound exists so a wedged goroutine cannot stall the whole shutdown path
// beyond the Compose stop_grace_period.
const hubCloseTimeout = 5 * time.Second

func (h *hub) close() {
	h.closeOnce.Do(func() {
		h.mutex.Lock()
		h.closed = true
		close(h.stop)
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
		if h.presence != nil && len(peers) > 0 {
			// Bound the presence sweep: a wedged Redis must not blow the
			// shutdown budget (one blocking DEL per peer), so run all deletions
			// concurrently under a 2s context deadline.
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			var sweep sync.WaitGroup
			for _, peer := range peers {
				sweep.Add(1)
				go func(deviceID string) {
					defer sweep.Done()
					_ = h.presence.DeletePresence(ctx, deviceID)
				}(peer.deviceID)
			}
			sweep.Wait()
			cancel()
		}
		done := make(chan struct{})
		go func() {
			h.waitGroup.Wait()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(hubCloseTimeout):
			// Sockets were already closed above; proceed even if a goroutine
			// is stuck, keeping the process exit path bounded.
		}
	})
}
func (h *hub) add(peer *peer) bool {
	peer.lastSeen = time.Now()
	h.mutex.Lock()
	if h.closed {
		h.mutex.Unlock()
		return false
	}
	previous := h.peers[peer.deviceID]
	if previous == nil && len(h.peers) >= h.config.MaxConnections {
		h.mutex.Unlock()
		return false
	}
	h.peers[peer.deviceID] = peer
	h.waitGroup.Add(2)
	h.mutex.Unlock()
	if previous != nil {
		closePeer(previous)
	}
	// Write presence before starting the read/write goroutines: if the socket
	// fails immediately, remove() clears presence after this point, so no
	// phantom online entry can be left behind by a delayed SetPresence.
	if h.presence != nil {
		_ = h.presence.SetPresence(context.Background(), peer.deviceID, h.presenceFor(peer), h.presenceTTL)
	}
	go h.write(peer)
	go h.read(peer)
	return true
}

func (h *hub) remove(peer *peer) {
	h.mutex.Lock()
	// Only the current peer clears presence: a replaced peer's read goroutine
	// may still exit after a duplicate connect, and must not erase the new
	// peer's presence.
	isCurrent := h.peers[peer.deviceID] == peer
	if isCurrent {
		delete(h.peers, peer.deviceID)
	}
	h.mutex.Unlock()
	if isCurrent && h.presence != nil {
		_ = h.presence.DeletePresence(context.Background(), peer.deviceID)
	}
	closePeer(peer)
}

func closePeer(peer *peer) {
	peer.stateMutex.Lock()
	defer peer.stateMutex.Unlock()
	peer.once.Do(func() {
		close(peer.done)
		if peer.socket != nil {
			_ = peer.socket.Close()
		}
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
		// The peer's deferred remove() runs with isCurrent==false once we already
		// deleted it, so it would never clear presence; clear it here explicitly.
		if h.presence != nil {
			_ = h.presence.DeletePresence(context.Background(), deviceID)
		}
		closePeer(peer)
	}
}

func (h *hub) write(peer *peer) {
	defer h.waitGroup.Done()
	defer h.remove(peer)
	for {
		select {
		case <-peer.done:
			return
		case frame := <-peer.outbound:
			peer.dequeue(frame)
			_ = peer.socket.SetWriteDeadline(time.Now().Add(15 * time.Second))
			if err := peer.socket.WriteMessage(frame.messageType, frame.data); err != nil {
				return
			}
		}
	}
}

func (h *hub) read(peer *peer) {
	defer h.waitGroup.Done()
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
	p.stateMutex.Lock()
	defer p.stateMutex.Unlock()
	select {
	case <-p.done:
		return false
	default:
	}
	if p.maxPendingFrames > 0 && p.pendingFrames >= p.maxPendingFrames {
		return false
	}
	frameBytes := int64(len(frame.data))
	if p.maxPendingBytes > 0 && frameBytes > p.maxPendingBytes-p.pendingBytes {
		return false
	}
	select {
	case p.outbound <- frame:
		p.pendingFrames++
		p.pendingBytes += frameBytes
		return true
	default:
		return false
	}
}

func (p *peer) dequeue(frame outboundFrame) {
	p.stateMutex.Lock()
	if p.pendingFrames > 0 {
		p.pendingFrames--
	}
	frameBytes := int64(len(frame.data))
	if frameBytes >= p.pendingBytes {
		p.pendingBytes = 0
	} else {
		p.pendingBytes -= frameBytes
	}
	p.stateMutex.Unlock()
}

func (h *hub) routeBinary(sender *peer, data []byte) {
	if !sender.allowFrame(len(data)) || len(data) < 25 || len(data) > maxBinaryFrameBytes || data[0] != 0x10 {
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

func (p *peer) allowFrame(size int) bool {
	p.stateMutex.Lock()
	defer p.stateMutex.Unlock()
	now := time.Now()
	if now.Sub(p.windowStartedAt) >= time.Second {
		p.windowStartedAt = now
		p.framesInWindow = 0
		p.bytesInWindow = 0
	}
	maxFrames := p.maxFramesPerSecond
	if maxFrames <= 0 {
		maxFrames = defaultMaxFramesPerSecondPerDevice
	}
	maxBytes := p.maxBytesPerSecond
	if maxBytes <= 0 {
		maxBytes = defaultMaxBytesPerSecondPerDevice
	}
	if p.framesInWindow >= maxFrames || int64(size) > maxBytes-p.bytesInWindow {
		return false
	}
	p.framesInWindow++
	p.bytesInWindow += int64(size)
	return true
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
