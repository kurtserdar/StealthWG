package wgserver

import (
	"strings"
	"testing"
)

func TestKeypairRoundTrip(t *testing.T) {
	priv, pub, err := GenerateKeypair()
	if err != nil {
		t.Fatal(err)
	}
	pub2, err := PublicKeyFromPrivate(priv)
	if err != nil {
		t.Fatal(err)
	}
	if pub != pub2 {
		t.Fatalf("pub mismatch: %s vs %s", pub, pub2)
	}
	if len(priv) != 44 || len(pub) != 44 {
		t.Fatalf("bad base64 lengths: %d %d", len(priv), len(pub))
	}
}

func TestConfigRoundTrip(t *testing.T) {
	c := &Config{PrivateKey: "PRIV", MaskKey: "PSK", ListenPort: 51820,
		Subnet: "10.8.0.0/24", PublicHost: "vpn.example.com", DNS: "1.1.1.1",
		Clients: []Client{{Name: "phone", PublicKey: "PUB", Address: "10.8.0.2/32"}}}
	got, err := ParseConfig(c.Marshal())
	if err != nil {
		t.Fatal(err)
	}
	if got.ListenPort != 51820 || got.PublicHost != "vpn.example.com" || len(got.Clients) != 1 ||
		got.Clients[0].Name != "phone" || got.Clients[0].Address != "10.8.0.2/32" {
		t.Fatalf("round trip mismatch: %+v", got)
	}
	if got.TransportOrDefault() != "mask" {
		t.Fatalf("default transport should be mask, got %q", got.TransportOrDefault())
	}
}

func TestConfigQUICRoundTrip(t *testing.T) {
	c := &Config{PrivateKey: "PRIV", MaskKey: "PSK", ListenPort: 443,
		Subnet: "10.8.0.0/24", PublicHost: "vpn.example.com", DNS: "1.1.1.1",
		Transport: "quic", SNI: "www.cloudflare.com"}
	got, err := ParseConfig(c.Marshal())
	if err != nil {
		t.Fatal(err)
	}
	if got.Transport != "quic" || got.SNI != "www.cloudflare.com" {
		t.Fatalf("quic round trip mismatch: %+v", got)
	}
	p := got.ClientProfile("CPRIV", "10.8.0.2/32")
	for _, want := range []string{"Transport = quic", "SNI = www.cloudflare.com", "Endpoint = vpn.example.com:443"} {
		if !strings.Contains(p, want) {
			t.Fatalf("quic profile missing %q\n%s", want, p)
		}
	}
}

func TestNextClientAddress(t *testing.T) {
	c := &Config{Subnet: "10.8.0.0/24", Clients: []Client{{Address: "10.8.0.2/32"}, {Address: "10.8.0.4/32"}}}
	a, err := c.NextClientAddress()
	if err != nil {
		t.Fatal(err)
	}
	if a != "10.8.0.3/32" {
		t.Fatalf("want 10.8.0.3/32 got %s", a)
	}
}

func TestClientProfileShape(t *testing.T) {
	c := &Config{PrivateKey: mustPriv(t), MaskKey: "PSKVALUE", ListenPort: 51820,
		PublicHost: "vpn.example.com", DNS: "1.1.1.1"}
	p := c.ClientProfile("CLIENTPRIV", "10.8.0.2/32")
	for _, want := range []string{"[Interface]", "PrivateKey = CLIENTPRIV", "Address = 10.8.0.2/32",
		"DNS = 1.1.1.1", "[Peer]", "Endpoint = vpn.example.com:51820", "AllowedIPs = 0.0.0.0/0",
		"[Stealth]", "MaskKey = PSKVALUE"} {
		if !strings.Contains(p, want) {
			t.Fatalf("profile missing %q\n%s", want, p)
		}
	}
}

func TestIpcConfigHex(t *testing.T) {
	c := &Config{PrivateKey: mustPriv(t), ListenPort: 51820,
		Clients: []Client{{PublicKey: mustPub(t), Address: "10.8.0.2/32"}}}
	s, err := c.IpcConfig()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(s, "listen_port=51820") || !strings.Contains(s, "private_key=") ||
		!strings.Contains(s, "public_key=") || !strings.Contains(s, "allowed_ip=10.8.0.2/32") {
		t.Fatalf("bad uapi: %s", s)
	}
}

func mustPriv(t *testing.T) string {
	p, _, err := GenerateKeypair()
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func mustPub(t *testing.T) string {
	_, p, err := GenerateKeypair()
	if err != nil {
		t.Fatal(err)
	}
	return p
}
