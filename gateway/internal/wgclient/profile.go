// Package wgclient is the StealthWG Linux client: it parses a client profile,
// drives wireguard-go through the masking/QUIC bind, and configures the interface
// and routes (full- or split-tunnel per the profile's AllowedIPs).
package wgclient

import (
	"bufio"
	"fmt"
	"strconv"
	"strings"
)

// ClientConfig is a parsed StealthWG client profile (wg-quick + [Stealth]).
type ClientConfig struct {
	PrivateKey    string   // base64
	Address       []string // [Interface] Address, e.g. 10.8.0.2/32
	DNS           []string // parsed; not applied in the MVP
	MTU           int      // [Interface] MTU (default 1420)
	PeerPublicKey string   // [Peer] PublicKey (base64)
	PresharedKey  string   // [Peer] PresharedKey (base64, optional)
	Endpoint      string   // [Peer] Endpoint host:port
	AllowedIPs    []string // [Peer] AllowedIPs
	Keepalive     int      // [Peer] PersistentKeepalive
	MaskKey       string   // [Stealth] MaskKey (base64)
	Transport     string   // [Stealth] Transport: "mask" (default) | "quic"
	SNI           string   // [Stealth] SNI (quic only)
}

// ParseProfile reads the [Interface]/[Peer]/[Stealth] profile text the app imports.
// The [Stealth] Endpoints fallback list is ignored in the MVP (single Endpoint).
func ParseProfile(raw string) (*ClientConfig, error) {
	c := &ClientConfig{MTU: 1420, Transport: "mask"}
	section := ""
	sc := bufio.NewScanner(strings.NewReader(raw))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(strings.Trim(line, "[]"))
			continue
		}
		k, v, ok := kv(line)
		if !ok {
			continue
		}
		switch section {
		case "interface":
			switch strings.ToLower(k) {
			case "privatekey":
				c.PrivateKey = v
			case "address":
				c.Address = splitList(v)
			case "dns":
				c.DNS = splitList(v)
			case "mtu":
				if n, err := strconv.Atoi(v); err == nil {
					c.MTU = n
				}
			}
		case "peer":
			switch strings.ToLower(k) {
			case "publickey":
				c.PeerPublicKey = v
			case "presharedkey":
				c.PresharedKey = v
			case "endpoint":
				c.Endpoint = v
			case "allowedips":
				c.AllowedIPs = splitList(v)
			case "persistentkeepalive":
				if n, err := strconv.Atoi(v); err == nil {
					c.Keepalive = n
				}
			}
		case "stealth":
			switch strings.ToLower(k) {
			case "maskkey":
				c.MaskKey = v
			case "transport":
				c.Transport = strings.ToLower(v)
			case "sni":
				c.SNI = v
			}
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if c.Transport == "" {
		c.Transport = "mask"
	}
	if c.PrivateKey == "" {
		return nil, fmt.Errorf("profile: missing [Interface] PrivateKey")
	}
	if c.PeerPublicKey == "" {
		return nil, fmt.Errorf("profile: missing [Peer] PublicKey")
	}
	if c.Endpoint == "" {
		return nil, fmt.Errorf("profile: missing [Peer] Endpoint")
	}
	return c, nil
}

func kv(line string) (string, string, bool) {
	i := strings.Index(line, "=")
	if i < 0 {
		return "", "", false
	}
	return strings.TrimSpace(line[:i]), strings.TrimSpace(line[i+1:]), true
}

func splitList(v string) []string {
	parts := strings.Split(v, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if t := strings.TrimSpace(p); t != "" {
			out = append(out, t)
		}
	}
	return out
}
