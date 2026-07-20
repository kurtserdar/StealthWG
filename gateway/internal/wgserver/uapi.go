package wgserver

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

// IpcConfig renders the wireguard-go UAPI 'set' configuration (keys in hex).
func (c *Config) IpcConfig() (string, error) {
	privHex, err := b64ToHex(c.PrivateKey)
	if err != nil {
		return "", fmt.Errorf("private key: %w", err)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "private_key=%s\n", privHex)
	fmt.Fprintf(&b, "listen_port=%d\n", c.ListenPort)
	b.WriteString("replace_peers=true\n")
	for _, cl := range c.Clients {
		pubHex, err := b64ToHex(cl.PublicKey)
		if err != nil {
			return "", fmt.Errorf("peer %s: %w", cl.Name, err)
		}
		fmt.Fprintf(&b, "public_key=%s\n", pubHex)
		fmt.Fprintf(&b, "allowed_ip=%s\n", cl.Address)
	}
	return b.String(), nil
}
