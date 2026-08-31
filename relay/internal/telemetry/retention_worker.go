// Background worker for server-side telemetry retention cleanup.

package telemetry

import (
	"context"
	"log/slog"
	"sync"
	"time"
)

type RetentionWorker struct {
	service  *Service
	interval time.Duration
	stopCh   chan struct{}
	wg       sync.WaitGroup
	logger   *slog.Logger
}

func NewRetentionWorker(service *Service, interval time.Duration) *RetentionWorker {
	if interval <= 0 {
		interval = 1 * time.Hour
	}
	return &RetentionWorker{
		service:  service,
		interval: interval,
		stopCh:   make(chan struct{}),
		logger:   slog.Default(),
	}
}

// WithLogger injects the structured logger used to report retention cycles.
// Call it before Start; a nil logger falls back to slog.Default.
func (w *RetentionWorker) WithLogger(logger *slog.Logger) *RetentionWorker {
	if logger == nil {
		logger = slog.Default()
	}
	w.logger = logger
	return w
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
				w.logger.Error("telemetry retention run failed", "error", err)
			} else if purged > 0 {
				w.logger.Info("telemetry retention purged old raw telemetry records", "purged", purged)
			}
		}
	}
}

func (w *RetentionWorker) Stop() {
	close(w.stopCh)
	w.wg.Wait()
}
