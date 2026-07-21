//go:build linux || windows

// Command stealthwg-client is the StealthWG CLI client (Linux + Windows): it
// connects to a StealthWG server using a client profile (masked or QUIC) and routes
// traffic per the profile's AllowedIPs. Runs in the foreground; stop it with Ctrl-C
// (or, when wrapped by systemd/a service, on stop).
package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/kurtserdar/StealthWG/gateway/internal/wgclient"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "up":
		cmdUp(os.Args[2:])
	case "version":
		fmt.Println("stealthwg-client")
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: stealthwg-client up <profile.conf> [--iface NAME] [--no-route]")
}

func cmdUp(args []string) {
	fs := flag.NewFlagSet("up", flag.ExitOnError)
	iface := fs.String("iface", "wg-stealth", "tunnel interface name")
	noRoute := fs.Bool("no-route", false, "do not change routes (test the tunnel only)")
	_ = fs.Parse(args)
	if fs.NArg() < 1 {
		usage()
		os.Exit(2)
	}
	if !elevated() {
		fatal("this needs elevated privileges (Linux: sudo; Windows: run as Administrator)")
	}

	data, err := os.ReadFile(fs.Arg(0))
	if err != nil {
		fatal("read profile: %v", err)
	}
	cfg, err := wgclient.ParseProfile(string(data))
	if err != nil {
		fatal("%v", err)
	}

	eng := &wgclient.Engine{}
	if err := eng.Up(cfg, *iface, !*noRoute); err != nil {
		eng.Down()
		fatal("up: %v", err)
	}
	defer eng.Down()

	transport := cfg.Transport
	if transport == "quic" && cfg.SNI != "" {
		transport = "quic/" + cfg.SNI
	}
	fmt.Printf("stealthwg-client up: %s via %s (%s). Ctrl-C to stop.\n", *iface, cfg.Endpoint, transport)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	fmt.Println("\nstealthwg-client stopping")
}

func fatal(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "error: "+format+"\n", a...)
	os.Exit(1)
}
