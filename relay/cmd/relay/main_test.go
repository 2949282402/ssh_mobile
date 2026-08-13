package main

import (
	"net/http"
	"testing"
	"time"

	"github.com/ssh-mobile/relay/internal/relay"
)

// TestNewHTTPServerAppliesWriteTimeout verifies the configurable HTTP write
// deadline is wired onto the server, closing the missing-write-deadline gap.
func TestNewHTTPServerAppliesWriteTimeout(t *testing.T) {
	config := relay.Config{
		Address:            ":0",
		HTTPReadTimeout:    10 * time.Second,
		HTTPWriteTimeout:   7 * time.Second,
		HTTPIdleTimeout:    30 * time.Second,
		HTTPMaxHeaderBytes: 8192,
	}
	server := newHTTPServer(config, http.NewServeMux())
	if server.WriteTimeout != config.HTTPWriteTimeout {
		t.Fatalf("WriteTimeout was not applied: got %v, want %v", server.WriteTimeout, config.HTTPWriteTimeout)
	}
	if server.ReadTimeout != config.HTTPReadTimeout || server.IdleTimeout != config.HTTPIdleTimeout {
		t.Fatalf("read/idle timeouts were not applied: read=%v idle=%v", server.ReadTimeout, server.IdleTimeout)
	}
	if server.MaxHeaderBytes != config.HTTPMaxHeaderBytes {
		t.Fatalf("MaxHeaderBytes was not applied: got %d, want %d", server.MaxHeaderBytes, config.HTTPMaxHeaderBytes)
	}
}
