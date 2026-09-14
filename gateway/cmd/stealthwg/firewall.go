package main

import (
	"fmt"
	"os/exec"
	"strings"

	"github.com/kurtserdar/StealthWG/gateway/internal/wgserver"
)

// ufwActive reports whether ufw is installed and enabled on this host.
func ufwActive() bool {
	out, err := exec.Command("ufw", "status").Output()
	return err == nil && strings.Contains(string(out), "Status: active")
}

// firewalldActive reports whether firewalld is running on this host.
func firewalldActive() bool {
	out, err := exec.Command("firewall-cmd", "--state").Output()
	return err == nil && strings.TrimSpace(string(out)) == "running"
}

// firewallHints renders post-init firewall guidance. A filtered UDP port drops
// handshakes silently (and a deny FORWARD policy blackholes tunnel traffic
// after a successful handshake), so spell out every layer we can detect.
func firewallHints(port int, ufw, firewalld bool) string {
	var b strings.Builder
	fmt.Fprintf(&b, "\nFirewalls: open %d/udp in your cloud provider's firewall/security group (if any).\n", port)
	if ufw {
		fmt.Fprintf(&b, "ufw is active on this host — allow the tunnel:\n")
		fmt.Fprintf(&b, "    sudo ufw allow %d/udp\n", port)
		fmt.Fprintf(&b, "    sudo ufw route allow in on %s\n", wgserver.IfaceName)
	}
	if firewalld {
		fmt.Fprintf(&b, "firewalld is running on this host — allow the tunnel:\n")
		fmt.Fprintf(&b, "    sudo firewall-cmd --permanent --add-port=%d/udp --add-masquerade && sudo firewall-cmd --reload\n", port)
	}
	return b.String()
}
