// Relay Data outbound backlog and inbound rate-window ownership.

package relay

import (
	"sync"
	"time"
)

type relayDataFlowBudget struct {
	mutex              sync.Mutex
	pendingFrames      int
	pendingBytes       int64
	maxPendingFrames   int
	maxPendingBytes    int64
	maxFramesPerSecond int
	maxBytesPerSecond  int64
	windowStartedAt    time.Time
	framesInWindow     int
	bytesInWindow      int64
}

func newRelayDataFlowBudget(config Config) relayDataFlowBudget {
	return relayDataFlowBudget{
		maxPendingFrames:   config.MaxPendingFramesPerDevice,
		maxPendingBytes:    config.MaxPendingBytesPerDevice,
		maxFramesPerSecond: config.MaxFramesPerSecondPerDevice,
		maxBytesPerSecond:  config.MaxBytesPerSecondPerDevice,
	}
}

// reserveOutbound atomically reserves one writer-queue entry. The caller must
// release it if the channel send loses its non-blocking race.
func (b *relayDataFlowBudget) reserveOutbound(size int) bool {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	if b.maxPendingFrames > 0 && b.pendingFrames >= b.maxPendingFrames {
		return false
	}
	frameBytes := int64(size)
	if b.maxPendingBytes > 0 && frameBytes > b.maxPendingBytes-b.pendingBytes {
		return false
	}
	b.pendingFrames++
	b.pendingBytes += frameBytes
	return true
}

func (b *relayDataFlowBudget) releaseOutbound(size int) {
	b.mutex.Lock()
	if b.pendingFrames > 0 {
		b.pendingFrames--
	}
	frameBytes := int64(size)
	if frameBytes >= b.pendingBytes {
		b.pendingBytes = 0
	} else {
		b.pendingBytes -= frameBytes
	}
	b.mutex.Unlock()
}

func (b *relayDataFlowBudget) allowInbound(size int) bool {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	now := time.Now()
	if now.Sub(b.windowStartedAt) >= time.Second {
		b.windowStartedAt = now
		b.framesInWindow = 0
		b.bytesInWindow = 0
	}
	maxFrames := b.maxFramesPerSecond
	if maxFrames <= 0 {
		maxFrames = defaultMaxFramesPerSecondPerDevice
	}
	maxBytes := b.maxBytesPerSecond
	if maxBytes <= 0 {
		maxBytes = defaultMaxBytesPerSecondPerDevice
	}
	if b.framesInWindow >= maxFrames || int64(size) > maxBytes-b.bytesInWindow {
		return false
	}
	b.framesInWindow++
	b.bytesInWindow += int64(size)
	return true
}
