//go:build linux

package wgclient

import (
	"encoding/base64"
	"fmt"
	"net"
	"os/exec"
	"strings"

	"github.com/kurtserdar/StealthWG/mask"
	"github.com/kurtserdar/StealthWG/wgbind"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

const padMax = 32

// Engine runs the client tunnel: wireguard-go through the masking/QUIC bind, plus
// the interface address and routes.
type Engine struct {
	dev   *device.Device
	iface string
	down  [][]string
}

// Up brings up the tunnel for cfg on the named interface. When applyRoutes is false
// the routes are skipped (useful for testing the tunnel alone).
func (e *Engine) Up(cfg *ClientConfig, iface string, applyRoutes bool) error {
	bind, err := buildBind(cfg)
	if err != nil {
		return err
	}
	tunDev, err := tun.CreateTUN(iface, cfg.MTU)
	if err != nil {
		return fmt.Errorf("create tun (need root?): %w", err)
	}
	e.iface = iface
	logger := device.NewLogger(device.LogLevelError, "stealthwg-client: ")
	e.dev = device.NewDevice(tunDev, bind, logger)

	uapi, err := cfg.UAPI()
	if err != nil {
		return err
	}
	if err := e.dev.IpcSet(uapi); err != nil {
		return fmt.Errorf("configure device: %w", err)
	}
	if err := e.dev.Up(); err != nil {
		return fmt.Errorf("device up: %w", err)
	}

	for _, a := range cfg.Address {
		if err := run("ip", "address", "add", a, "dev", iface); err != nil {
			return fmt.Errorf("set address %s: %w", a, err)
		}
	}
	if err := run("ip", "link", "set", "mtu", fmt.Sprint(cfg.MTU), "up", "dev", iface); err != nil {
		return fmt.Errorf("link up: %w", err)
	}

	if applyRoutes {
		epIP, err := resolveIP(cfg.Endpoint)
		if err != nil {
			return fmt.Errorf("resolve endpoint %q: %w", cfg.Endpoint, err)
		}
		gw, dif := defaultRoute()
		up, down := RoutePlan(cfg.AllowedIPs, epIP, gw, dif, iface)
		e.down = down
		for _, args := range up {
			if err := run("ip", args...); err != nil {
				return fmt.Errorf("route %v: %w", args, err)
			}
		}
	}
	return nil
}

// Down removes the routes and closes the device (which removes the interface).
func (e *Engine) Down() {
	for _, args := range e.down {
		_ = run("ip", args...)
	}
	if e.dev != nil {
		e.dev.Close()
	}
}

func buildBind(cfg *ClientConfig) (conn.Bind, error) {
	if cfg.Transport == "quic" {
		return wgbind.NewQUIC(cfg.SNI), nil
	}
	psk, err := base64.StdEncoding.DecodeString(cfg.MaskKey)
	if err != nil {
		return nil, fmt.Errorf("mask key: %w", err)
	}
	codec, err := mask.NewCodec(psk, padMax)
	if err != nil {
		return nil, fmt.Errorf("codec: %w", err)
	}
	return wgbind.New(conn.NewStdNetBind(), codec), nil
}

func resolveIP(endpoint string) (string, error) {
	addr, err := net.ResolveUDPAddr("udp", endpoint)
	if err != nil {
		return "", err
	}
	return addr.IP.String(), nil
}

// defaultRoute parses `ip route show default` for the gateway and interface.
func defaultRoute() (gw, iface string) {
	out, err := exec.Command("ip", "route", "show", "default").Output()
	if err != nil {
		return "", ""
	}
	f := strings.Fields(string(out))
	for i, t := range f {
		if t == "via" && i+1 < len(f) {
			gw = f[i+1]
		}
		if t == "dev" && i+1 < len(f) {
			iface = f[i+1]
		}
	}
	return gw, iface
}

func run(name string, args ...string) error {
	return exec.Command(name, args...).Run()
}
