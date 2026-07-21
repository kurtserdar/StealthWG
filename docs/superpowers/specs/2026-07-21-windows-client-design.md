# Windows Client (CLI) — Design

**Date:** 2026-07-21
**Status:** Approved, ready for planning

## Goal

A **command-line Windows client** (`stealthwg-client.exe`) that connects to a
StealthWG server with the same profile the apps/Linux client use — masked or QUIC —
and routes traffic per the profile's `AllowedIPs` (full- or split-tunnel). Built for
**both `windows/amd64` and `windows/arm64`** from macOS via Go cross-compilation.
Userspace WireGuard over **Wintun**; no kernel driver of ours.

## Reuse vs new

The masking core is already cross-platform and CGO-free, so most of the Linux client
is reused unchanged:

- **Reused (no changes):** `wgclient/profile.go` (ParseProfile), `wgclient/uapi.go`
  (UAPI), `wgbind` (mask + QUIC binds), `quictransport`, `mask`, `wireguard-go`.
  wireguard-go's Windows `tun` uses **Wintun** (`golang.zx2c4.com/wintun`, already an
  indirect dep), so `tun.CreateTUN(name, mtu)` works on Windows too.
- **New (Windows-specific):** a Windows route plan (`netsh` commands), a Windows
  engine (Wintun TUN + `netsh` IP/MTU + routes + teardown), an admin check, CLI
  build-tag wiring, and shipping `wintun.dll`.

## Windows specifics

### Routing — `netsh` instead of `ip`
Same full/split logic as Linux, different command syntax. Full-tunnel pins the
endpoint to the real gateway and routes everything else through the tunnel with two
`/1` routes:

```
netsh interface ipv4 add route prefix=<ep>/32     interface="<default-if>" nexthop=<default-gw>
netsh interface ipv4 add route prefix=0.0.0.0/1   interface="<wintun-iface>"
netsh interface ipv4 add route prefix=128.0.0.0/1 interface="<wintun-iface>"
```
Split-tunnel: one `add route prefix=<cidr> interface="<iface>"` per CIDR. Teardown is
the matching `delete route`.

### Default gateway discovery
Windows has no `ip route show default`. Use PowerShell `Get-NetRoute`:
`Get-NetRoute -DestinationPrefix 0.0.0.0/0 | sort RouteMetric | select -First 1` →
`NextHop` (gateway) + `InterfaceAlias` (interface name for the pin).

### Interface (address + MTU) via `netsh`
```
netsh interface ipv4 set address name="<iface>" static <ip> <netmask>
netsh interface ipv4 set subinterface "<iface>" mtu=<mtu> store=active
```
The CIDR from `[Interface] Address` is split into `<ip> <netmask>` (prefix → mask).
The Wintun adapter's name is the interface name we pass to `tun.CreateTUN`.

### `wintun.dll`
wireguard-go loads `wintun.dll` from the executable's directory. We ship the matching
DLL next to the `.exe` (amd64 / arm64). A `scripts/fetch-wintun.sh` downloads the
official `wintun.net` zip and extracts `bin/amd64/wintun.dll` + `bin/arm64/wintun.dll`.

### Admin
Creating a Wintun adapter and editing routes needs **Administrator**. The client
checks the process token and errors early with "run as Administrator" if not elevated.

## Components

### `gateway/internal/wgclient/routing.go` (modify — pure, tested)
Add `RoutePlanWindows(allowedIPs []string, endpointIP, defaultGW, defaultIf, iface string) (up, down [][]string)`
returning the `netsh` argument lists (executor runs `netsh <args>`). Same full/split
logic as `RoutePlan`; IPv4 only in MVP. Kept in the un-tagged `routing.go` so it
compiles and is tested on macOS.

### `gateway/internal/wgclient/engine_windows.go` (new — `windows` only via filename)
`Engine` (same shape as the Linux one: `Up(cfg, iface, applyRoutes) error`, `Down()`):
`tun.CreateTUN(iface, mtu)` (Wintun) → `device.NewDevice(tun, mask/QUIC bind)` →
`IpcSet` → `Up`; then `netsh` for address + MTU; resolve the endpoint; PowerShell for
the default gateway/interface; run `RoutePlanWindows` up commands. `Down()` runs the
delete commands and closes the device (removes the adapter).

### `gateway/cmd/stealthwg-client/` (modify)
- `main.go`: change the build tag to `//go:build linux || windows`; replace the inline
  `os.Geteuid()` check with a platform `elevated()`.
- `main_other.go`: `//go:build !linux && !windows` (stub for macOS etc.).
- `elevate_unix.go` (`!windows`): `elevated()` = `os.Geteuid() == 0`.
- `elevate_windows.go` (windows): `elevated()` = process-token elevation check
  (`golang.org/x/sys/windows`).

### `scripts/fetch-wintun.sh` (new) + `scripts/build-packages.sh` (modify)
Fetch `wintun.dll` (both arches). `build-packages.sh` cross-builds
`stealthwg-client-windows-amd64.exe` + `-arm64.exe` and places each next to its
`wintun.dll` in `dist/`.

## Data flow

1. On Windows (Admin), place the profile + the matching `wintun.dll` next to the exe.
2. `stealthwg-client.exe up home.conf` → parse → Wintun adapter → mask/QUIC tunnel →
   `netsh` address/MTU/routes per `AllowedIPs`.
3. Ctrl-C (or the wrapping service) → teardown.

## Error handling

- Not elevated → "run as Administrator" error before touching anything.
- `wintun.dll` missing/arch-mismatched → `tun.CreateTUN` error with a clear hint.
- Endpoint DNS failure → error before configuring.
- Partial-up failure → best-effort `Down()`.

## Testing

- **Unit (pure, Go, runs on macOS):** `RoutePlanWindows` (full-tunnel `netsh` set incl.
  pinned endpoint + `/1`s; split per-CIDR; reverse `delete`). Profile/UAPI already
  covered.
- **Build:** cross-compile `windows/amd64` + `windows/arm64` from macOS, CGO-free.
- **Device (user):** run on the VMware Fusion Windows VM (Admin + `wintun.dll`), end-
  to-end against a server. arm64 for an Apple-Silicon VM, amd64 for x64.

## Out of scope (YAGNI / follow-ups)

- DNS application, IPv6 full-tunnel, multi-endpoint fallback (as with the Linux MVP).
- A Windows **Service** wrapper for always-on (foreground + admin for now).
- Authenticode **code-signing** (unsigned triggers SmartScreen; fine for personal use).
- A GUI. Android client (separate roadmap item).
