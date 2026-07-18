// Command stealthwg-gateway unmasks StealthWG client traffic and relays it to
// an unmodified upstream WireGuard endpoint.
package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/kurtserdar/StealthWG/gateway/internal/config"
	"github.com/kurtserdar/StealthWG/mask"
	"github.com/kurtserdar/StealthWG/gateway/internal/relay"
)

func main() {
	cfg, err := config.Parse(os.Args[1:])
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	codec, err := mask.NewCodec(cfg.PSK, cfg.PadMax)
	if err != nil {
		log.Fatalf("codec: %v", err)
	}
	r, err := relay.New(cfg.Listen, cfg.Upstream, codec, cfg.Timeout)
	if err != nil {
		log.Fatalf("relay: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	log.Printf("stealthwg-gateway listening on %s, upstream %s", r.LocalAddr(), cfg.Upstream)
	if err := r.Run(ctx); err != nil {
		log.Fatalf("run: %v", err)
	}
	log.Print("stealthwg-gateway stopped")
}
