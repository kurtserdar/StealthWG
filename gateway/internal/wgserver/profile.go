package wgserver

import (
	"fmt"
	"strings"
)

// ClientProfile builds the StealthWG client .conf that the app imports: standard
// wg-quick config with the server as the peer, plus a [Stealth] MaskKey section.
func (c *Config) ClientProfile(clientPrivateKey, address string) string {
	serverPub, _ := PublicKeyFromPrivate(c.PrivateKey)
	var b strings.Builder
	b.WriteString("[Interface]\n")
	fmt.Fprintf(&b, "PrivateKey = %s\n", clientPrivateKey)
	fmt.Fprintf(&b, "Address = %s\n", address)
	if c.DNS != "" {
		fmt.Fprintf(&b, "DNS = %s\n", c.DNS)
	}
	b.WriteString("MTU = 1280\n\n[Peer]\n")
	fmt.Fprintf(&b, "PublicKey = %s\n", serverPub)
	fmt.Fprintf(&b, "Endpoint = %s:%d\n", c.PublicHost, c.ListenPort)
	b.WriteString("AllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n\n[Stealth]\n")
	fmt.Fprintf(&b, "MaskKey = %s\n", c.MaskKey)
	return b.String()
}
