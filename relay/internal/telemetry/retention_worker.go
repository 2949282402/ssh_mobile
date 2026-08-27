// Background worker for server-side telemetry retention cleanup.

package telemetry

import (
	"context"
	"log"
	"sync"
	"time"
)

type RetentionWorker struct {
	service  *Service
	interval time.Duration
	stopCh   chan struct{}
	wg       sync.WaitGroup
}

func NewRetentionWorker(service *Service, interval time.Duration) *RetentionWorker {
	if interval <= 0 {
		interval = 1 * time.Hour
	}
	return &RetentionWorker{
		service:  service,
		interval: interval,
		stopCh:   make(chan struct{}),
	}
}

func (w *RetentionWorker) Start() {
	w.wg.Add(1)
	go w.run()
}

func (w *RetentionWorker) run() {
	defer w.wg.Done()
	ticker := time.NewTicker(w.interval)
	defer ticker.Stop()

	for {
		select {
		case <-w.stopCh:
			return
		case <-ticker.C:
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
			purged, err := w.service.PurgeRetention(ctx)
			cancel()
			if err != nil {
				log.Printf("[telemetry-retention] retention run failed: %v", err)
			} else if purged > 0 {
				log.Printf("[telemetry-retention] successfully purged %d old raw telemetry records", purged)
			}
		}
	}
}

func (w *RetentionWorker) Stop() {
	close(w.stopCh)
	w.wg.Wait()
}
