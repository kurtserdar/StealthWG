package wgclient

import (
	"reflect"
	"strings"
	"testing"
)

const maskProfile = `[Interface]
PrivateKey = QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzND0=
Address = 10.8.0.2/32
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = cHVia2V5cHVia2V5cHVia2V5cHVia2V5cHVia2V5MDA=
Endpoint = gw.example.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25

[Stealth]
MaskKey = bWFza2tleW1hc2trZXltYXNra2V5bWFza2tleTEyMw==
`

func TestParseMaskProfile(t *testing.T) {
	c, err := ParseProfile(maskProfile)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if c.Address[0] != "10.8.0.2/32" || c.MTU != 1280 || c.DNS[0] != "1.1.1.1" {
		t.Fatalf("interface fields: %+v", c)
	}
	if c.Endpoint != "gw.example.com:51820" || c.AllowedIPs[0] != "0.0.0.0/0" || c.Keepalive != 25 {
		t.Fatalf("peer fields: %+v", c)
	}
	if c.Transport != "mask" || c.MaskKey == "" {
		t.Fatalf("stealth fields: %+v", c)
	}
}

func TestParseQUICProfileAndDefaults(t *testing.T) {
	raw := `[Interface]
PrivateKey = QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzND0=

[Peer]
PublicKey = cHVia2V5cHVia2V5cHVia2V5cHVia2V5cHVia2V5MDA=
Endpoint = gw.example.com:443
AllowedIPs = 0.0.0.0/0

[Stealth]
MaskKey = bWFza2tleW1hc2trZXltYXNra2V5bWFza2tleTEyMw==
Transport = quic
SNI = www.cloudflare.com
`
	c, err := ParseProfile(raw)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if c.Transport != "quic" || c.SNI != "www.cloudflare.com" {
		t.Fatalf("quic fields: %+v", c)
	}
	if c.MTU != 1420 { // default when absent
		t.Fatalf("expected default MTU 1420, got %d", c.MTU)
	}
}

func TestParseMissingFields(t *testing.T) {
	if _, err := ParseProfile("[Interface]\nAddress = 10.0.0.2/32\n"); err == nil {
		t.Fatal("expected error for missing PrivateKey/Peer")
	}
}

func TestUAPI(t *testing.T) {
	c, _ := ParseProfile(maskProfile)
	c.PresharedKey = "cHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrMDA="
	uapi, err := c.UAPI()
	if err != nil {
		t.Fatalf("uapi: %v", err)
	}
	for _, want := range []string{"private_key=", "public_key=", "preshared_key=",
		"endpoint=gw.example.com:51820", "persistent_keepalive_interval=25",
		"replace_allowed_ips=true", "allowed_ip=0.0.0.0/0"} {
		if !strings.Contains(uapi, want) {
			t.Fatalf("uapi missing %q\n%s", want, uapi)
		}
	}
	// Keys must be hex (64 chars for a 32-byte key), not base64.
	for _, line := range strings.Split(uapi, "\n") {
		if strings.HasPrefix(line, "private_key=") && len(line) != len("private_key=")+64 {
			t.Fatalf("private key not 64 hex chars: %q", line)
		}
	}
}

func TestRoutePlanFullTunnel(t *testing.T) {
	up, down := RoutePlan([]string{"0.0.0.0/0"}, "203.0.113.9", "192.168.1.1", "eth0", "wg-stealth")
	want := [][]string{
		{"route", "add", "203.0.113.9/32", "via", "192.168.1.1", "dev", "eth0"},
		{"route", "add", "0.0.0.0/1", "dev", "wg-stealth"},
		{"route", "add", "128.0.0.0/1", "dev", "wg-stealth"},
	}
	if !reflect.DeepEqual(up, want) {
		t.Fatalf("full-tunnel up mismatch:\n got %v\nwant %v", up, want)
	}
	// down reverses and turns add→del.
	if down[0][1] != "del" || down[len(down)-1][2] != "203.0.113.9/32" {
		t.Fatalf("down mismatch: %v", down)
	}
}

func TestRoutePlanSplitTunnel(t *testing.T) {
	up, _ := RoutePlan([]string{"10.0.0.0/24", "192.168.5.0/24"}, "203.0.113.9", "192.168.1.1", "eth0", "wg-stealth")
	want := [][]string{
		{"route", "add", "10.0.0.0/24", "dev", "wg-stealth"},
		{"route", "add", "192.168.5.0/24", "dev", "wg-stealth"},
	}
	if !reflect.DeepEqual(up, want) {
		t.Fatalf("split-tunnel up mismatch:\n got %v\nwant %v", up, want)
	}
}
