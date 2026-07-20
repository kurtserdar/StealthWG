# Native packaging — all-in-one masked WireGuard server + `stealthwg` CLI — design

**Date:** 2026-07-20
**Status:** Approved (option A — all-in-one), ready for implementation planning

## Goal

Ship a single self-contained Linux binary that IS a masked WireGuard server —
mirroring the iOS/macOS client architecture (wireguard-go + MaskBind in one
process) on the server side. One `stealthwg init` stands up a complete masked VPN
server; `stealthwg add-client` mints client profiles. Packaged as `.deb`/`.rpm`/
`.apk` (amd64 + arm64) via nfpm; raw cross-compiled binaries for other OSes.

The existing **relay** (`stealthwg-gateway`) is **kept** — it serves the "mask in
front of an existing/kernel WireGuard" case (RB5009→MikroTik, RouterOS/k8s
containers). All-in-one is the flagship native product; the relay stays for those
scenarios. Docker/OCI also stays for container platforms.

## Why all-in-one (architecture symmetry)

- iOS/macOS client: `wireguard-go` device + **MaskBind** (`wgbind`) + platform
  TUN/routing (NetworkExtension).
- All-in-one server: the **same** `wireguard-go` device + **MaskBind** + a Linux
  TUN + NAT. The mask codec is symmetric (client Seals, server Opens, and vice
  versa), so the server's `wgbind.MaskBind` bind unmasks inbound and masks outbound
  — no new codec. One concept (wireguard-go + mask) powers both ends.

## Background (current code)

- `gateway/` — Go module: relay (`cmd/stealthwg-gateway`, `internal/{config,relay}`),
  imports `mask` via `replace ../mask`. Static, CGO-free, cross-compiles (verified).
- `wgbind/` — `MaskBind` wrapping `conn.Bind` with the `mask` codec (the client's
  masking layer). `New(inner conn.Bind, obf Obfuscator)`.
- `mask/` — the UdpMask codec (`NewCodec`, `Seal`, `Open`).
- wireguard-go (`golang.zx2c4.com/wireguard`) is pure Go (device/tun/conn), CGO-free.

## Architecture

### `gateway/internal/wgserver` — the masked WireGuard server engine

- Creates a TUN (`tun.CreateTUN("wg-stealth", mtu)`).
- Builds the device: `device.NewDevice(tun, wgbind.New(conn.NewStdNetBind(), codec), logger)`
  where `codec = mask.NewCodec(psk, padMax)`.
- Configures WireGuard via UAPI (`device.IpcSet`): server private key, listen port,
  and each peer (`public_key`, `allowed_ip`).
- OS networking (mirrors what `wg-quick` does), via `ip`/`sysctl`/`iptables`:
  set the interface address (`<subnet>.1/24`) + up, `net.ipv4.ip_forward=1`, and a
  MASQUERADE for `<subnet>` out the default interface. Torn down on stop.
- `Reload()` re-applies peers from config (driven by SIGHUP) with no restart.

**Testable pure helpers** (`wgserver`, Go unit tests): the UAPI config string
render (server + peers), next-free client IP over a peer list, and the client
profile text (`[Interface]/[Peer]/[Stealth]`, the shape the app parses).

### `gateway/cmd/stealthwg` — daemon + CLI

- `stealthwg up` — the daemon (systemd `ExecStart`): read config, start the server
  engine, run until signalled; on SIGHUP `Reload()`, on SIGTERM tear down.
- `stealthwg init [--public-host H] [--subnet 10.8.0.0/24] [--dns 1.1.1.1] [--listen 51820]`
  1. require root; resolve public host (flag, else best-effort detect).
  2. generate server X25519 keypair (Go `curve25519`) + mask PSK (32 random bytes).
  3. write `/etc/stealthwg/server.conf` (privkey, psk, listen, subnet, public-host,
     empty peers), `0600`.
  4. `add-client "client1"`, then `systemctl enable --now stealthwg`.
  5. print the first client profile + QR (`qrencode` if present).
- `stealthwg add-client NAME`
  1. generate client keypair; allocate the next free `<subnet>.N`.
  2. append the peer (name/pubkey/ip) to the config; `systemctl reload stealthwg`
     (SIGHUP → live peer apply, no downtime) when running.
  3. print the StealthWG client profile (`Endpoint <public-host>:<listen>`,
     `[Stealth] MaskKey = <psk>`) + QR.
- `stealthwg status` — running state + peer count.

### Config store — `/etc/stealthwg/server.conf`

A small structured file (INI/TOML-ish) the daemon reads and `add-client` edits:
`PrivateKey`, `MaskKey` (PSK), `ListenPort`, `Subnet`, `PublicHost`, `DNS`, and a
`[Client "name"]` block per peer (`PublicKey`, `Address`). Parsed/rendered by a
pure, tested serializer.

### Dependency story (cleaner than two-piece)

- **No `wireguard-tools` dependency** — keys via Go `curve25519`, the WG engine is
  embedded wireguard-go. The package `Recommends: iproute2, iptables` (present on
  essentially all Linux) for the address/NAT setup, and `qrencode` (optional) for QR.

## Packaging (`packaging/`) + build

- `packaging/nfpm.yaml` — one config → deb/rpm/apk. Contents: `/usr/bin/stealthwg`,
  the systemd unit, and `/etc/stealthwg/` created empty. `recommends`: iproute2,
  iptables, qrencode. Arch templated per build. Post-install prints "run
  `stealthwg init`" — no automatic system mutation.
- `packaging/stealthwg.service` — `ExecStart=/usr/bin/stealthwg up`,
  `ExecReload=/bin/kill -HUP $MAINPID`, `AmbientCapabilities=CAP_NET_ADMIN`,
  `Restart=on-failure`.
- `scripts/build-packages.sh` — cross-compile `stealthwg` for `linux/{amd64,arm64}`
  (+ `darwin`/`windows`/`freebsd` raw binaries), run `nfpm package` per format/arch
  into `dist/`. A GitHub Actions release job can call it.

## Testing

- **Go units** (`go test ./...` in `gateway`): config serialize/parse round-trip,
  next-free-IP, UAPI render, client-profile assembly.
- **Build:** `stealthwg` cross-compiles CGO-free for linux amd64/arm64; a `.deb`
  builds with nfpm (installed via `go install`) and `dpkg -c` shows the layout.
- **End-to-end** (`init` → real masked handshake) is user-side: needs a root Linux
  host with TUN. The unsigned/local checks cover build + package + pure logic.

## Non-goals (YAGNI)

- Replacing the relay (kept for existing-WG / container cases — "our everything").
- Kernel-WG mode in the all-in-one (userspace wireguard-go; kernel path is the
  relay + external WG).
- nftables-native NAT (v1 shells to `iptables` like wg-quick; nft later).
- Web UI, multi-server, IPv6-only, OpenWrt `.ipk` (later/on request).

## Trade-offs (honest)

- Userspace wireguard-go is slower than kernel WG — fine for self-host/personal
  scale (the target); high-throughput servers can use the relay + kernel WG instead.
- We own peer/IP/NAT management, but wireguard-go + MaskBind do the protocol/mask
  heavy lifting. Precedent: Tailscale runs userspace wireguard-go + TUN in one
  binary.

## Security notes

- Keys/PSK generated on the host, stored `0600`; nothing leaves the box.
- Post-install performs no networking changes; `init` is the explicit, auditable
  step and detects/keeps an existing setup rather than clobbering it.
- Strategy: packaging eases self-hosting; keep public-repo distribution quiet
  (broad reach is the DPI-signature risk).
