package wgserver

import (
	"encoding/base64"
	"fmt"
	"os/exec"
	"strings"

	"github.com/kurtserdar/StealthWG/mask"
	"github.com/kurtserdar/StealthWG/wgbind"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

const (
	ifaceName = "wg-stealth"
	ifaceMTU  = 1420
	padMax    = 32
)

// Engine runs the masked WireGuard server: wireguard-go driven through the
// StealthWG MaskBind, plus the Linux interface/NAT plumbing (like wg-quick).
type Engine struct {
	dev    *device.Device
	tun    tun.Device
	subnet string
	wan    string
}

// Start brings up the TUN, the masked WireGuard device, and NAT for cfg.
func (e *Engine) Start(cfg *Config) error {
	pskBytes, err := base64.StdEncoding.DecodeString(cfg.MaskKey)
	if err != nil {
		return fmt.Errorf("mask key: %w", err)
	}
	codec, err := mask.NewCodec(pskBytes, padMax)
	if err != nil {
		return fmt.Errorf("codec: %w", err)
	}

	tunDev, err := tun.CreateTUN(ifaceName, ifaceMTU)
	if err != nil {
		return fmt.Errorf("create tun: %w", err)
	}
	e.tun = tunDev

	logger := device.NewLogger(device.LogLevelError, "stealthwg: ")
	e.dev = device.NewDevice(tunDev, wgbind.New(conn.NewStdNetBind(), codec), logger)

	uapi, err := cfg.IpcConfig()
	if err != nil {
		return err
	}
	if err := e.dev.IpcSet(uapi); err != nil {
		return fmt.Errorf("configure device: %w", err)
	}
	if err := e.dev.Up(); err != nil {
		return fmt.Errorf("device up: %w", err)
	}

	e.subnet = cfg.Subnet
	e.wan = defaultWANInterface()
	return e.applyNetworking()
}

// Reload re-applies the peer set without restarting the tunnel.
func (e *Engine) Reload(cfg *Config) error {
	uapi, err := cfg.IpcConfig()
	if err != nil {
		return err
	}
	return e.dev.IpcSet(uapi)
}

// Stop tears down the device and removes the NAT rule.
func (e *Engine) Stop() {
	if e.subnet != "" && e.wan != "" {
		_ = run("iptables", "-t", "nat", "-D", "POSTROUTING", "-s", e.subnet, "-o", e.wan, "-j", "MASQUERADE")
	}
	if e.dev != nil {
		e.dev.Close()
	}
}

func (e *Engine) applyNetworking() error {
	base := subnetBase(e.subnet)
	if base == "" {
		return fmt.Errorf("invalid subnet %q", e.subnet)
	}
	if err := run("ip", "address", "add", base+".1/24", "dev", ifaceName); err != nil {
		return fmt.Errorf("set address: %w", err)
	}
	if err := run("ip", "link", "set", "up", "dev", ifaceName); err != nil {
		return fmt.Errorf("link up: %w", err)
	}
	_ = run("sysctl", "-w", "net.ipv4.ip_forward=1")
	if e.wan != "" {
		// Idempotent: add only if missing.
		if run("iptables", "-t", "nat", "-C", "POSTROUTING", "-s", e.subnet, "-o", e.wan, "-j", "MASQUERADE") != nil {
			if err := run("iptables", "-t", "nat", "-A", "POSTROUTING", "-s", e.subnet, "-o", e.wan, "-j", "MASQUERADE"); err != nil {
				return fmt.Errorf("nat: %w", err)
			}
		}
	}
	return nil
}

func run(name string, args ...string) error {
	return exec.Command(name, args...).Run()
}

// defaultWANInterface parses `ip route show default` for the outbound interface.
func defaultWANInterface() string {
	out, err := exec.Command("ip", "route", "show", "default").Output()
	if err != nil {
		return ""
	}
	fields := strings.Fields(string(out))
	for i, f := range fields {
		if f == "dev" && i+1 < len(fields) {
			return fields[i+1]
		}
	}
	return ""
}
