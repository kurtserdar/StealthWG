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

	// Optionally run a QUIC relay alongside the UDP mask relay.
	var quicRelay *relay.QUICRelay
	if cfg.QUIC != "" {
		quicRelay, err = relay.NewQUIC(cfg.QUIC, cfg.Upstream, cfg.Timeout)
		if err != nil {
			log.Fatalf("quic relay: %v", err)
		}
	}

	errc := make(chan error, 2)
	log.Printf("stealthwg-gateway listening on %s (mask), upstream %s", r.LocalAddr(), cfg.Upstream)
	go func() { errc <- r.Run(ctx) }()
	if quicRelay != nil {
		log.Printf("stealthwg-gateway listening on %s (quic)", quicRelay.Addr())
		go func() { errc <- quicRelay.Run(ctx) }()
	}

	if err := <-errc; err != nil {
		log.Fatalf("run: %v", err)
	}
	log.Print("stealthwg-gateway stopped")
}
