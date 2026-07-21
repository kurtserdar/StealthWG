package wgclient

import (
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strings"
)

func b64ToHex(b64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}

// UAPI renders the wireguard-go 'set' configuration for this client (keys in hex):
// the private key plus a single peer (the server) with its allowed IPs, endpoint,
// optional preshared key and keepalive.
func (c *ClientConfig) UAPI() (string, error) {
	privHex, err := b64ToHex(c.PrivateKey)
	if err != nil {
		return "", fmt.Errorf("private key: %w", err)
	}
	pubHex, err := b64ToHex(c.PeerPublicKey)
	if err != nil {
		return "", fmt.Errorf("peer public key: %w", err)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "private_key=%s\n", privHex)
	b.WriteString("replace_peers=true\n")
	fmt.Fprintf(&b, "public_key=%s\n", pubHex)
	if c.PresharedKey != "" {
		pskHex, err := b64ToHex(c.PresharedKey)
		if err != nil {
			return "", fmt.Errorf("preshared key: %w", err)
		}
		fmt.Fprintf(&b, "preshared_key=%s\n", pskHex)
	}
	fmt.Fprintf(&b, "endpoint=%s\n", c.Endpoint)
	if c.Keepalive > 0 {
		fmt.Fprintf(&b, "persistent_keepalive_interval=%d\n", c.Keepalive)
	}
	b.WriteString("replace_allowed_ips=true\n")
	for _, ip := range c.AllowedIPs {
		fmt.Fprintf(&b, "allowed_ip=%s\n", ip)
	}
	return b.String(), nil
}
