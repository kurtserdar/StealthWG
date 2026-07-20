package wgserver

import (
	"bufio"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// Client is one peer of the masked WireGuard server.
type Client struct {
	Name      string
	PublicKey string // base64
	Address   string // e.g. 10.8.0.2/32
}

// Config is the persisted server state (/etc/stealthwg/server.conf).
type Config struct {
	PrivateKey string // base64 server private key
	MaskKey    string // base64 mask PSK
	ListenPort int
	Subnet     string // e.g. 10.8.0.0/24 (assumed /24)
	PublicHost string
	DNS        string
	Clients    []Client
}

// Marshal renders the config file text.
func (c *Config) Marshal() string {
	var b strings.Builder
	fmt.Fprintf(&b, "PrivateKey = %s\n", c.PrivateKey)
	fmt.Fprintf(&b, "MaskKey = %s\n", c.MaskKey)
	fmt.Fprintf(&b, "ListenPort = %d\n", c.ListenPort)
	fmt.Fprintf(&b, "Subnet = %s\n", c.Subnet)
	fmt.Fprintf(&b, "PublicHost = %s\n", c.PublicHost)
	fmt.Fprintf(&b, "DNS = %s\n", c.DNS)
	for _, cl := range c.Clients {
		fmt.Fprintf(&b, "\n[Client %q]\nPublicKey = %s\nAddress = %s\n", cl.Name, cl.PublicKey, cl.Address)
	}
	return b.String()
}

// ParseConfig reads config file text back into a Config.
func ParseConfig(s string) (*Config, error) {
	c := &Config{}
	var cur *Client
	sc := bufio.NewScanner(strings.NewReader(s))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[Client") {
			name := strings.Trim(strings.TrimSuffix(strings.TrimPrefix(line, "[Client "), "]"), "\"")
			c.Clients = append(c.Clients, Client{Name: name})
			cur = &c.Clients[len(c.Clients)-1]
			continue
		}
		k, v, ok := kv(line)
		if !ok {
			continue
		}
		if cur != nil {
			switch k {
			case "PublicKey":
				cur.PublicKey = v
			case "Address":
				cur.Address = v
			}
			continue
		}
		switch k {
		case "PrivateKey":
			c.PrivateKey = v
		case "MaskKey":
			c.MaskKey = v
		case "ListenPort":
			c.ListenPort, _ = strconv.Atoi(v)
		case "Subnet":
			c.Subnet = v
		case "PublicHost":
			c.PublicHost = v
		case "DNS":
			c.DNS = v
		}
	}
	return c, sc.Err()
}

func kv(line string) (string, string, bool) {
	i := strings.Index(line, "=")
	if i < 0 {
		return "", "", false
	}
	return strings.TrimSpace(line[:i]), strings.TrimSpace(line[i+1:]), true
}

// NextClientAddress returns the next free <base>.N/32 (server takes .1). /24 only.
func (c *Config) NextClientAddress() (string, error) {
	base := subnetBase(c.Subnet)
	if base == "" {
		return "", fmt.Errorf("invalid subnet %q", c.Subnet)
	}
	used := map[int]bool{1: true}
	for _, cl := range c.Clients {
		if n := hostOctet(cl.Address, base); n > 0 {
			used[n] = true
		}
	}
	free := []int{}
	for n := 2; n < 255; n++ {
		if !used[n] {
			free = append(free, n)
		}
	}
	sort.Ints(free)
	if len(free) == 0 {
		return "", fmt.Errorf("subnet full")
	}
	return fmt.Sprintf("%s.%d/32", base, free[0]), nil
}

func subnetBase(subnet string) string {
	p := strings.SplitN(subnet, "/", 2)
	octs := strings.Split(p[0], ".")
	if len(octs) != 4 {
		return ""
	}
	return strings.Join(octs[:3], ".")
}

func hostOctet(addr, base string) int {
	a := strings.SplitN(addr, "/", 2)[0]
	if !strings.HasPrefix(a, base+".") {
		return 0
	}
	n, _ := strconv.Atoi(strings.TrimPrefix(a, base+"."))
	return n
}
