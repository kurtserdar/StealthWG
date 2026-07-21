package wgclient

import "strings"

// RoutePlan returns the `ip` argument lists to add (up) and remove (down) for the
// given AllowedIPs. Full-tunnel (0.0.0.0/0 present) pins the server endpoint to the
// real gateway and routes everything else through the tunnel with two /1 routes (so
// the tunnel's own outer packets reach the server via the normal network while all
// other traffic goes through the tunnel, and the existing default route is left
// intact). Split-tunnel adds one route per CIDR. IPv4 only in the MVP; IPv6 CIDRs
// are skipped.
func RoutePlan(allowedIPs []string, endpointIP, defaultGW, defaultIf, iface string) (up, down [][]string) {
	full := false
	var splits []string
	for _, cidr := range allowedIPs {
		switch cidr {
		case "0.0.0.0/0":
			full = true
		case "::/0":
			// IPv6 full-tunnel deferred.
		default:
			splits = append(splits, cidr)
		}
	}

	add := func(args ...string) { up = append(up, args) }
	if full {
		if endpointIP != "" && defaultGW != "" && defaultIf != "" {
			add("route", "add", endpointIP+"/32", "via", defaultGW, "dev", defaultIf)
		}
		add("route", "add", "0.0.0.0/1", "dev", iface)
		add("route", "add", "128.0.0.0/1", "dev", iface)
	}
	for _, cidr := range splits {
		if strings.Contains(cidr, ":") {
			continue // skip IPv6 in the MVP
		}
		add("route", "add", cidr, "dev", iface)
	}

	// down is the reverse of up with add→del.
	for i := len(up) - 1; i >= 0; i-- {
		del := make([]string, len(up[i]))
		copy(del, up[i])
		del[1] = "del"
		down = append(down, del)
	}
	return up, down
}

// RoutePlanWindows is the Windows equivalent of RoutePlan: it returns `netsh`
// argument lists (executor runs `netsh <args>`). Same full/split logic; the endpoint
// pin uses the default interface's numeric index (spaces-safe) while the tunnel/split
// routes use the (space-free) tunnel interface name. IPv4 only in the MVP.
func RoutePlanWindows(allowedIPs []string, endpointIP, defaultGW, defaultIfIndex, iface string) (up, down [][]string) {
	full := false
	var splits []string
	for _, cidr := range allowedIPs {
		switch cidr {
		case "0.0.0.0/0":
			full = true
		case "::/0":
			// IPv6 full-tunnel deferred.
		default:
			splits = append(splits, cidr)
		}
	}

	add := func(args ...string) { up = append(up, args) }
	if full {
		if endpointIP != "" && defaultGW != "" && defaultIfIndex != "" {
			add("interface", "ipv4", "add", "route", "prefix="+endpointIP+"/32",
				"interface="+defaultIfIndex, "nexthop="+defaultGW)
		}
		add("interface", "ipv4", "add", "route", "prefix=0.0.0.0/1", "interface="+iface)
		add("interface", "ipv4", "add", "route", "prefix=128.0.0.0/1", "interface="+iface)
	}
	for _, cidr := range splits {
		if strings.Contains(cidr, ":") {
			continue
		}
		add("interface", "ipv4", "add", "route", "prefix="+cidr, "interface="+iface)
	}

	for i := len(up) - 1; i >= 0; i-- {
		del := make([]string, len(up[i]))
		copy(del, up[i])
		del[2] = "delete" // "add" → "delete"
		down = append(down, del)
	}
	return up, down
}
