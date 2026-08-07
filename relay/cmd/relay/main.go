// Relay v1 服务启动入口；配置和路由均由 internal/relay 统一管理。

package main

import (
	"log"
	"net/http"
	"os"
	"time"

	"github.com/ssh-mobile/relay/internal/relay"
)

// main 加载环境配置并启动 Relay HTTP/WebSocket 服务。
func main() {
	config, err := relay.ConfigFromEnvironment()
	if err != nil {
		log.Fatal(err)
	}
	server := relay.NewServer(config)
	defer server.Close()

	mux := http.NewServeMux()
	server.RegisterRoutes(mux)
	httpServer := &http.Server{
		Addr:              config.Address,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("relay listening on %s", config.Address)
	if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Printf("relay stopped: %v", err)
		os.Exit(1)
	}
}
