package main

import (
	"log"
	"net/http"
	"os"
	"time"

	"github.com/ssh-mobile/relay/internal/relay"
)

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
