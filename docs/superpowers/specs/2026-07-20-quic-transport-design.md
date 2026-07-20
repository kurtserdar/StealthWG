# QUIC transport (full) — design

**Date:** 2026-07-20
**Status:** Approved (do everything), ready for implementation planning

## Goal

Add a **real QUIC** transport alongside UdpMask, so WireGuard can ride inside a
genuine HTTP/3-shaped QUIC connection on UDP **443** and blend with legitimate
QUIC traffic — for DPI that fingerprints the protocol, not just the port. Complete
scope: client (iOS/macOS) + relay + all-in-one server + profile selection + the
multi-endpoint fallback.

Decided: **real quic-go** (not a hand-rolled imitation — a fake is more detectable
than random bytes); WireGuard rides **QUIC DATAGRAM frames** (unreliable/unordered,
like UDP — streams would add head-of-line blocking and break WireGuard); server
uses a **self-signed** cert with a **configurable SNI**; the profile selects the
transport via `[Stealth] Transport = quic`.

## Architecture reality

Masking (`wgbind.MaskBind`) is a per-datagram `Obfuscator` (`Seal`/`Open`). QUIC is
stateful/connection-oriented and does **not** fit that seam. It fits one level up,
at **`conn.Bind`**: `wireguard-go`'s `device.NewDevice(tun, bind, …)` accepts any
`conn.Bind`, so **QUICBind is a sibling of MaskBind** — a whole `conn.Bind` that
tunnels WireGuard's UDP packets over a QUIC connection instead of masking them.

```
UdpMask:  WG ─► MaskBind (Seal) ─► UDP :51819
QUIC:     WG ─► QUICBind ─► QUIC DATAGRAM ─► :443 (looks like HTTP/3)
```

## Components

### 1. `quictransport` package (new, repo root; shared by client + servers)

The QUIC framing, reused everywhere:

- `Dial(ctx, addr, sni string) (*Session, error)` — client: opens a QUIC
  connection (quic-go) with `EnableDatagrams`, `InsecureSkipVerify` (self-signed),
  `ServerName = sni`, ALPN `h3` (blend as HTTP/3). `Session.SendDatagram([]byte)` /
  `Session.ReceiveDatagram() ([]byte, error)`.
- `Listen(addr string, tlsCert tls.Certificate) (*Listener, error)` — server:
  QUIC listener with datagrams enabled. `Accept` yields per-connection `*Session`s.
- `SelfSignedCert() (tls.Certificate, error)` — generate an ephemeral cert.
- Pure-testable helpers: framing is just datagram in/out (WireGuard packets ≤ MTU
  fit one datagram); no fragmentation needed at 1280 MTU.

### 2. Client — `wgbind.QUICBind` (a `conn.Bind`)

- `Open(port)` dials the QUIC session to the server (from the peer endpoint) and
  returns a receive func that reads datagrams. `Send(pkt, ep)` sends a datagram.
  `ParseEndpoint` parses `host:port`. One session (client → one server).
- Selected instead of `MaskBind` when the profile's transport is `quic`.

### 3. Bridge (iOS/macOS) — transport selection

The wireguard-go bridge (`patches/wireguard-apple/0003-quic-transport.patch`) adds
`wgSetTransport(mode, sni)` (like `wgSetStealthKey`): when `mode == "quic"`,
`wgTurnOn` builds `QUICBind` (dialing the peer endpoint on the QUIC port) instead of
`MaskBind`. Swift passes the transport + SNI from the profile to the extension
(`Tunnel/StealthBridge.h` + `PacketTunnelProvider`).

### 4. Server — relay QUIC mode

The relay gains a QUIC listen mode (`STEALTHWG_QUIC=:443` or transport flag): accept
QUIC sessions, read each datagram (a WireGuard packet), forward it as UDP to the
upstream WireGuard, and send replies back on the originating session — the same
NAT-like per-client session model as the UDP relay, QUIC-fronted. The relay can run
mask (`:51819`) and QUIC (`:443`) side by side.

### 5. Server — all-in-one `wgserver` QUIC bind

The engine can bind wireguard-go over QUIC: a `QUICServerBind` (`conn.Bind`) wraps
the QUIC `Listener`, maps each connection to a synthetic endpoint so WireGuard can
route replies to the right session (receive tags datagrams with the connection's
endpoint; `Send` looks the connection up). `stealthwg init --transport quic`
listens on 443 with a self-signed cert.

### 6. Profile + fallback

- `StealthProfile` parses `[Stealth] Transport = quic` (default `mask`) and an
  optional `[Stealth] SNI`. Stored in `providerConfiguration`.
- The multi-endpoint fallback list can mix transports (each endpoint carries its
  transport); the client tries mask `:51819`, then QUIC `:443`, until a handshake.

### 7. iOS/macOS UI

The profile form/detail surface **Transport** (Mask / QUIC) and **SNI** (advanced),
so a from-scratch profile can choose QUIC. Imported profiles honor `[Stealth]
Transport`.

## Dependency notes

- `quic-go` is a separate module; it coexists with the 2023-pinned `wireguard-go`
  (they don't share the conflicting `conn.Bind` API). Add `quic-go` to `wgbind`
  (client), `gateway` (relay + all-in-one), and the bridge go.mod. Keep
  `wireguard-go` pinned to the 2023 version (wgbind/bridge compatibility) — do not
  `go mod tidy` it upward.
- CGO-free: quic-go is pure Go; cross-compiles for linux amd64/arm64 and iphoneos.

## Testing

- **Go units:** `quictransport` datagram round-trip through a local listener;
  profile `Transport`/`SNI` parse (Swift `scripts/test-parser.sh`); relay QUIC
  session forward (loopback). QUICBind round-trip through a fake QUIC gateway
  (mirrors the existing `wgbind` MaskBind test).
- **Cross-compile:** wgbind/gateway build for linux + iphoneos, CGO-free.
- **Device builds:** unsigned iOS + macOS builds green with the bridge patch
  (libwg-go.a links QUICBind).
- **End-to-end** (real QUIC handshake over 443) — user-side on a real device +
  server.

## Non-goals (YAGNI)

- HTTP/3 request/response mimicry beyond ALPN + QUIC shape (real QUIC connection is
  the blend; we don't serve actual web content).
- Certificate pinning / ECH (self-signed + InsecureSkipVerify for v1; note it).
- Reliable-stream tunneling (DATAGRAM only — correct for WireGuard).

## Security notes

- QUIC adds a TLS layer, but WireGuard remains the only trusted crypto; the QUIC TLS
  is for blending, so `InsecureSkipVerify` is acceptable (WireGuard authenticates
  the peer). Document this clearly.
- No new secrets persisted beyond the existing profile; SNI is non-sensitive.
- Strategy: QUIC is for a censor that defeats mask-on-443; keep distribution quiet
  (broad reach is the fingerprint-DB risk).
