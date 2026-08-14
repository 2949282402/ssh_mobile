// Relay v1 服务启动入口；配置和路由均由 internal/relay 统一管理。

package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/ssh-mobile/relay/internal/relay"
)

// main 加载环境配置并启动 Relay HTTP/WebSocket 服务。
func main() {
	seedFile := flag.String("seed-enrollments", "", "path to a JSON array of enrollments to seed into storage before serving")
	flag.Parse()

	config, err := relay.ConfigFromEnvironment()
	if err != nil {
		log.Fatal(err)
	}
	server, err := relay.OpenServer(config)
	if err != nil {
		log.Fatal(err)
	}
	defer server.Close()

	if *seedFile != "" {
		if err := seedEnrollments(server, *seedFile); err != nil {
			log.Fatalf("seed enrollments: %v", err)
		}
	}

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	httpServer := newHTTPServer(config, mux)
	log.Printf("relay listening on %s", config.Address)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	serverErrors := make(chan error, 1)
	go func() {
		serverErrors <- httpServer.ListenAndServe()
	}()

	select {
	case err := <-serverErrors:
		if err != nil && err != http.ErrServerClosed {
			log.Printf("relay stopped: %v", err)
			os.Exit(1)
		}
	case <-ctx.Done():
		// Bounded shutdown: HTTP graceful shutdown (15s) is followed by a hub
		// close that is itself bounded (hubCloseTimeout). The Compose
		// stop_grace_period must exceed this full 15s + 5s budget so Docker
		// does not SIGKILL the process mid-sequence.
		shutdownContext, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		if err := httpServer.Shutdown(shutdownContext); err != nil {
			log.Printf("relay HTTP shutdown failed: %v", err)
			_ = httpServer.Close()
		}
		cancel()
		server.Close()
	}
}

// seedEnrollments loads a JSON array of EnrolledDevice records and seeds them
// into the configured storage, for one-time migration from a memory-only
// deployment to MySQL.
func seedEnrollments(server *relay.Server, path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var enrollments []relay.EnrolledDevice
	if err := json.Unmarshal(data, &enrollments); err != nil {
		return err
	}
	return server.SeedEnrollments(context.Background(), enrollments)
}

// newHTTPServer builds the HTTP server with bounded read, write, header and
// idle limits. It is separated so the write deadline wiring is directly
// testable.
func newHTTPServer(config relay.Config, handler http.Handler) *http.Server {
	return &http.Server{
		Addr:              config.Address,
		Handler:           handler,
		ReadTimeout:       config.HTTPReadTimeout,
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      config.HTTPWriteTimeout,
		IdleTimeout:       config.HTTPIdleTimeout,
		MaxHeaderBytes:    config.HTTPMaxHeaderBytes,
	}
}
