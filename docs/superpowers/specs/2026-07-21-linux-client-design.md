# Linux Client (CLI) — Design

**Date:** 2026-07-21
**Status:** Approved, ready for planning

## Goal

A **command-line Linux client** (`stealthwg-client`) that connects to a StealthWG
server using the same client profile the iOS/macOS apps import — masked (UDP mask)
or QUIC — and routes traffic per the profile's `AllowedIPs` (full-tunnel `0.0.0.0/0`
or split-tunnel CIDRs). Userspace `wireguard-go` + the shared masking core; no GUI.

## Why CLI

Linux VPN clients are conventionally CLI (`wg-quick`, tailscale). The target user is
technical, integrates with `systemd`, and doesn't need a GUI. YAGNI — a GUI can come
later only if asked.

## What it reuses

The masking core is already in Go and cross-platform: `wgbind.MaskBind` /
`wgbind.QUICBind`, `quictransport`, `mask.Codec`, and `wireguard-go` (2023 pin). The
client is essentially the iOS bridge's logic as a standalone Linux binary: parse a
profile → TUN → `wireguard-go` + the right bind → configure the interface + routes.

## Full-tunnel vs split-tunnel — no build-time choice

The client does **not** pick a mode. It honors the profile's `AllowedIPs`:
- `0.0.0.0/0` → full-tunnel (all traffic exits at the server).
- `10.0.0.0/24` (or several CIDRs) → split-tunnel (only those go through the tunnel).

Same binary, same code. The user decides by editing the profile — identical to
iOS/macOS. On Apple, NetworkExtension does the routing + loop avoidance for us; on
Linux there is no such framework, so the client does it with `ip` commands.

### Loop avoidance for full-tunnel (transport-agnostic)

Routing everything into the tunnel would loop the tunnel's own outer packets (to the
server endpoint). Instead of `wg-quick`'s fwmark trick (which can't mark quic-go's
internal socket), we **pin the endpoint route to the real gateway** and use the
split-default `/1` routes — works for both mask and QUIC:

```
ip route add <endpoint-ip>/32 via <default-gw> dev <default-if>   # server via real net
ip route add 0.0.0.0/1        dev <wg-iface>                       # everything else…
ip route add 128.0.0.0/1      dev <wg-iface>                       # …through the tunnel
```

The pinned `/32` is more specific than the `/1`s, so the tunnel's outer packets reach
the server via the normal network while all other traffic goes through the tunnel.
The existing default route is never deleted (the two `/1`s override it). Split-tunnel
is simpler: one `ip route add <cidr> dev <wg-iface>` per CIDR, no endpoint pin.

## Architecture

```
profile.conf ─► wgclient.ParseProfile ─► ClientConfig
                                            │  .UAPI() → wireguard-go IpcSet
                                            ▼
   Engine.Up:  tun.CreateTUN → device.NewDevice(tun, MaskBind|QUICBind) → IpcSet → Up
               ip address add / link mtu up
               RoutePlan(allowedIPs, endpointIP, defaultGW/if, iface) → run `ip …`
   (foreground; SIGINT/SIGTERM → Engine.Down → reverse routes, close device)
```

## Components

### `gateway/internal/wgclient/profile.go` (new, pure — tested)
`ClientConfig` + `ParseProfile(raw string) (*ClientConfig, error)`:
```go
type ClientConfig struct {
    PrivateKey  string   // base64
    Address     []string // Interface Address (e.g. 10.8.0.2/32)
    DNS         []string // parsed, not applied in MVP
    MTU         int      // default 1420 if absent
    PeerPublicKey string
    PresharedKey  string // optional
    Endpoint      string // host:port
    AllowedIPs    []string
    Keepalive     int
    MaskKey       string // [Stealth] MaskKey
    Transport     string // "mask" (default) | "quic"
    SNI           string // [Stealth] SNI (quic)
}
```
Reuses the same `[Interface]/[Peer]/[Stealth]` grammar the app writes. Only the
`[Stealth] Endpoints` fallback list is ignored in MVP (single Endpoint).

### `gateway/internal/wgclient/uapi.go` (new, pure — tested)
`(c *ClientConfig) UAPI() (string, error)` → the hex-key `wireguard-go` IPC string:
`private_key`, one `[peer]` with `public_key`, optional `preshared_key`, `endpoint`,
`persistent_keepalive_interval`, and an `allowed_ip` line per CIDR. (Mirrors the
server's `IpcConfig`, client-shaped.)

### `gateway/internal/wgclient/routing.go` (new, pure — tested)
```go
func RoutePlan(allowedIPs []string, endpointIP, defaultGW, defaultIf, iface string) (up, down [][]string)
```
Returns the `ip` argument lists (executor runs `ip <args...>`). Full-tunnel when
`allowedIPs` contains `0.0.0.0/0`: pin endpoint + `0.0.0.0/1`+`128.0.0.0/1`; else one
route per CIDR. `down` is the reverse (`del`). IPv4 in MVP; IPv6 (`::/0` → `::/1` +
`8000::/1`) is a follow-up.

### `gateway/internal/wgclient/engine.go` (new, Linux — not unit-tested)
`Engine.Up(cfg)`: build the bind (`wgbind.New(StdNetBind, mask.Codec)` for mask,
`wgbind.NewQUIC(sni)` for quic), `tun.CreateTUN(iface, mtu)`,
`device.NewDevice(tun, bind, logger)`, `IpcSet(cfg.UAPI())`, `Up()`, then
`ip address add` each Address, `ip link set mtu … up`, resolve the endpoint host,
read the default gateway/iface (`ip route show default`), run `RoutePlan` up commands.
`Engine.Down()`: run `RoutePlan` down commands, `device.Close()` (removes the TUN).

### `gateway/cmd/stealthwg-client/main.go` (new)
- `stealthwg-client up <profile.conf> [--iface wg-stealth] [--no-route]` — runs in the
  foreground, holds the tunnel, and on SIGINT/SIGTERM tears everything down cleanly.
  Requires root (TUN + `ip`).
- `stealthwg-client version`.
- Background use is via `systemd` (below), not a daemonize/pidfile scheme.

### `packaging/stealthwg-client@.service` (new) + build wiring
A templated unit so `systemctl start stealthwg-client@home` runs
`stealthwg-client up /etc/stealthwg-client/home.conf`. `scripts/build-packages.sh`
gains a `stealthwg-client` binary target; nfpm client packages are a follow-up.

## Data flow

1. User obtains a profile (same `.conf` the app imports) → `sudo stealthwg-client up home.conf`.
2. Client parses it, brings up `wg-stealth` with mask/QUIC, configures address + routes.
3. Traffic flows per `AllowedIPs` (full or split). Ctrl-C (or `systemctl stop`) tears down.

## Error handling

- Not root → clear "run with sudo" error.
- Missing/invalid profile fields (no PrivateKey/Endpoint/PeerPublicKey) → parse error.
- Endpoint DNS resolution failure → error before touching the interface.
- On any Up failure after partial setup → best-effort Down (remove what was added).
- `--no-route` skips routing (for testing the tunnel without changing the routes).

## Testing

- **Unit (pure, Go):** `ParseProfile` (mask + quic profiles, defaults, missing
  fields); `UAPI` (hex keys, allowed_ip lines, keepalive, optional PSK); `RoutePlan`
  (full-tunnel command set incl. pinned endpoint + `/1`s; split-tunnel per-CIDR;
  reverse `down`).
- **Build:** `go build` + CGO-free cross-compile `linux/amd64` + `linux/arm64`.
- **Device (user):** a real Linux host running `up` against a StealthWG server, phone-
  style end-to-end — deferred to a Linux test box.

## Out of scope (YAGNI / follow-ups)

- DNS management (resolvconf/systemd-resolved) — MVP parses DNS but does not apply it.
- IPv6 full-tunnel routing.
- Multi-endpoint fallback (`[Stealth] Endpoints`) — MVP uses the single `[Peer] Endpoint`.
- A daemonizing `down` command (use `systemd`/signals).
- nfpm `.deb/.rpm/.apk` for the client (reuse the server's pattern later).
- Windows/Android clients (separate roadmap items).
