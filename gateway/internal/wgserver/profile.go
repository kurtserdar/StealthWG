package wgserver

import (
	"fmt"
	"strings"
)

// AddClient generates a keypair for a new client, appends it to the config, and
// returns the profile to import on the device. The caller persists the config.
func (c *Config) AddClient(name string) (string, error) {
	priv, pub, err := GenerateKeypair()
	if err != nil {
		return "", err
	}
	addr, err := c.NextClientAddress()
	if err != nil {
		return "", err
	}
	c.Clients = append(c.Clients, Client{Name: name, PublicKey: pub, Address: addr})
	return c.ClientProfile(priv, addr), nil
}

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
	if c.TransportOrDefault() == "quic" {
		b.WriteString("Transport = quic\n")
		if c.SNI != "" {
			fmt.Fprintf(&b, "SNI = %s\n", c.SNI)
		}
	}
	return b.String()
}
