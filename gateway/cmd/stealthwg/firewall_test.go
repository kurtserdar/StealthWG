package main

import (
	"strings"
	"testing"
)

func TestFirewallHintsAlwaysMentionCloudFirewallAndPort(t *testing.T) {
	h := firewallHints(51820, false, false)
	if !strings.Contains(h, "51820/udp") || !strings.Contains(strings.ToLower(h), "cloud") {
		t.Fatalf("missing cloud/port hint:\n%s", h)
	}
}

func TestFirewallHintsUFW(t *testing.T) {
	h := firewallHints(51820, true, false)
	for _, want := range []string{"ufw allow 51820/udp", "ufw route allow in on wg-stealth"} {
		if !strings.Contains(h, want) {
			t.Fatalf("ufw hints missing %q:\n%s", want, h)
		}
	}
}

func TestFirewallHintsFirewalld(t *testing.T) {
	h := firewallHints(443, false, true)
	for _, want := range []string{"--add-port=443/udp", "--add-masquerade", "firewall-cmd --reload"} {
		if !strings.Contains(h, want) {
			t.Fatalf("firewalld hints missing %q:\n%s", want, h)
		}
	}
}
