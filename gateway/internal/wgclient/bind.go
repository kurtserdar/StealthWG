package wgclient

import (
	"encoding/base64"
	"fmt"
	"net"
	"os/exec"

	"github.com/kurtserdar/StealthWG/mask"
	"github.com/kurtserdar/StealthWG/wgbind"
	"golang.zx2c4.com/wireguard/conn"
)

const padMax = 32

// buildBind returns the transport bind for the profile: QUIC when Transport==quic,
// otherwise the UDP mask bind. Shared by the Linux and Windows engines.
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

// resolveIP resolves the endpoint host:port to its IP (for the full-tunnel pin).
func resolveIP(endpoint string) (string, error) {
	addr, err := net.ResolveUDPAddr("udp", endpoint)
	if err != nil {
		return "", err
	}
	return addr.IP.String(), nil
}

// cidrToIPMask splits "10.8.0.2/24" into the host IP and dotted netmask.
func cidrToIPMask(cidr string) (ip, mask string, err error) {
	host, ipnet, err := net.ParseCIDR(cidr)
	if err != nil {
		return "", "", err
	}
	return host.String(), net.IP(ipnet.Mask).String(), nil
}

func run(name string, args ...string) error {
	return exec.Command(name, args...).Run()
}
