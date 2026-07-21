package wgclient

import (
	"fmt"
	"os/exec"
	"strings"

	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

// Engine runs the client tunnel on Windows: wireguard-go over Wintun through the
// masking/QUIC bind, plus interface (netsh) and routes. Needs Administrator; loads
// wintun.dll from the executable's directory.
type Engine struct {
	dev  *device.Device
	down [][]string
}

// Up brings up the tunnel for cfg on the named Wintun adapter.
func (e *Engine) Up(cfg *ClientConfig, iface string, applyRoutes bool) error {
	bind, err := buildBind(cfg)
	if err != nil {
		return err
	}
	tunDev, err := tun.CreateTUN(iface, cfg.MTU)
	if err != nil {
		return fmt.Errorf("create wintun adapter (run as Administrator; wintun.dll present?): %w", err)
	}
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

	for i, a := range cfg.Address {
		ip, mask, err := cidrToIPMask(a)
		if err != nil {
			return fmt.Errorf("address %s: %w", a, err)
		}
		verb := "add"
		if i == 0 {
			verb = "set"
		}
		if err := run("netsh", "interface", "ipv4", verb, "address",
			"name="+iface, "static", ip, mask); err != nil {
			return fmt.Errorf("set address %s: %w", a, err)
		}
	}
	if err := run("netsh", "interface", "ipv4", "set", "subinterface",
		iface, fmt.Sprintf("mtu=%d", cfg.MTU), "store=active"); err != nil {
		return fmt.Errorf("set mtu: %w", err)
	}

	if applyRoutes {
		epIP, err := resolveIP(cfg.Endpoint)
		if err != nil {
			return fmt.Errorf("resolve endpoint %q: %w", cfg.Endpoint, err)
		}
		gw, ifIndex := defaultRoute()
		up, down := RoutePlanWindows(cfg.AllowedIPs, epIP, gw, ifIndex, iface)
		e.down = down
		for _, args := range up {
			if err := run("netsh", args...); err != nil {
				return fmt.Errorf("route %v: %w", args, err)
			}
		}
	}
	return nil
}

// Down removes the routes and closes the device (which removes the adapter).
func (e *Engine) Down() {
	for _, args := range e.down {
		_ = run("netsh", args...)
	}
	if e.dev != nil {
		e.dev.Close()
	}
}

// defaultRoute returns the current default gateway and its interface index via
// PowerShell's Get-NetRoute (interface index is spaces-safe for netsh).
func defaultRoute() (gw, ifIndex string) {
	out, err := exec.Command("powershell", "-NoProfile", "-Command",
		`Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric | Select-Object -First 1 | ForEach-Object { "$($_.NextHop) $($_.ifIndex)" }`).Output()
	if err != nil {
		return "", ""
	}
	f := strings.Fields(string(out))
	if len(f) >= 2 {
		return f[0], f[1]
	}
	return "", ""
}
