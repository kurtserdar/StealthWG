# iOS Production Integration — Design

**Status:** Approved (2026-07-18)
**Depends on:** `2026-07-18-udpmask-transport.md` (wire format & gateway, already built).

This phase integrates the WireGuard engine into the iOS app and inserts the
UdpMask obfuscation at the engine's UDP I/O boundary, so a real device can hand
shake with an upstream WireGuard endpoint through the gateway. It is the
production path (not a throwaway PoC): masking lives in wireguard-go's `conn.Bind`,
the same place production obfuscated-WireGuard forks (e.g. AmneziaWG) put it.

## 1. Engine choice — the shipped wireguard-apple engine

We use `wireguard-apple` at tag **`1.0.16-27`** (the latest tag; the wrapper repo
has been dormant since Feb 2023). Its Go bridge pins wireguard-go
`v0.0.0-20230209153558-1e2c3e5a3c14`.

Rationale: the WireGuard protocol is frozen, so this engine interoperates
perfectly with any WireGuard server, and it is the exact engine the official
WireGuard iOS app ships today — proven and stable. The newer wireguard-go (2026)
adds GSO/GRO batching (throughput) and a **batched** `conn.Bind` interface, but
porting the wrapper's bridge to it is fragile and device-unverifiable. The engine
version is orthogonal to masking correctness; bumping it is deferred to an
isolated, testable performance upgrade after the milestone works. The simpler
single-packet `conn.Bind` of the 2023 engine also makes our masking Bind simpler.

## 2. Masking injection — a custom `conn.Bind`

wireguard-go abstracts its UDP socket behind `conn.Bind`. In the pinned version
the interface is single-packet:

```go
type Bind interface {
    Open(port uint16) (fns []ReceiveFunc, actualPort uint16, err error)
    Close() error
    SetMark(mark uint32) error
    Send(b []byte, ep Endpoint) error
    ParseEndpoint(s string) (Endpoint, error)
}
type ReceiveFunc func(b []byte) (n int, ep Endpoint, err error)
```

We implement **`MaskBind`**, which wraps the default `conn.NewStdNetBind()`:

- `Send(b, ep)`: `masked := codec.Seal(b)`; `inner.Send(masked, ep)`.
- `Open`: call `inner.Open`, then wrap each returned `ReceiveFunc` so that after
  the inner func fills a scratch buffer with a masked datagram, we `codec.Open`
  it and copy the recovered WireGuard packet into the caller's buffer, returning
  the recovered length. A datagram that fails `Open` is dropped by returning a
  zero-length read that the wrapper skips (never surfaced as data).
- `Close`, `SetMark`, `ParseEndpoint`: delegate to the inner bind unchanged.

The upstream `Endpoint` is the gateway (`host:51819`); WireGuard is unaware that
the bytes on the wire are masked.

### Bridge patch point

`Sources/WireGuardKitGo/api-apple.go:110` currently reads:

```go
dev := device.NewDevice(tun, conn.NewStdNetBind(), logger)
```

We change it to build a `MaskBind` around the default bind, keyed by a
process-global PSK set before turn-on (below).

## 3. One codec, shared Go module

Because the masking Bind is Go, the **client and gateway share one codec** — no
Swift port, no cross-language interop drift. `internal/mask` is promoted to a
standalone module so both consumers can import it:

- New module at repo root: **`github.com/kurtserdar/StealthWG/mask`** (its own
  `go.mod`), holding the codec, tests, and `testdata/vectors.json`.
- `gateway` imports it (`gateway/go.mod` `require` + `replace ../mask`).
- The wireguard-apple bridge imports it (bridge `go.mod` `require` + `replace`
  to the repo-relative path), added as part of our patch set.

`vectors.json` remains a regression contract (now guarding one shared codec).

## 4. PSK threading — minimal bridge patch

To avoid touching WireGuardKit's Swift `WireGuardAdapter` (which builds the uapi
settings and the `NEPacketTunnelNetworkSettings`), the PSK is passed out-of-band:

- Add one exported bridge function `wgSetStealthKey(key *C.char)` that decodes the
  base64 PSK and stores it (and a derived `mask.Codec`) in a package global.
- Patched `wgTurnOn` uses `newMaskBind(global codec)` when a key is set, else
  falls back to `conn.NewStdNetBind()` (so plain WireGuard still works with no
  key — this is how sub-project B validates the engine before masking exists).
- Our `PacketTunnelProvider` calls `wgSetStealthKey` before `adapter.start(...)`.

Turn-on is sequential, so a package global is safe.

## 5. Profile / config format

The app imports a standard WireGuard `.conf` plus a StealthWG section:

```
[Interface]
PrivateKey = ...
Address = ...

[Peer]
PublicKey = ...
Endpoint = <gateway public IP>:51819   # the gateway's mask port
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25

[Stealth]
MaskKey = <base64 32-byte PSK>
```

`[Interface]`/`[Peer]` are parsed by WireGuardKit's own parser. Our importer
extracts and strips the `[Stealth]` section, stores `MaskKey` in the App Group
(`group.com.stealthwg`), and the extension passes it to `wgSetStealthKey`.

### MTU

Masking adds `12 (nonce) + 2 (len) + pad` bytes. The `[Interface] MTU` (or the
adapter's setting) is lowered so the masked outer datagram stays under ~1280
bytes on carrier/ISP paths. Exact value tuned on device.

## 6. Decomposition (each is its own spec → plan → implementation)

| # | Sub-project | Deliverable & what is verifiable here |
|---|---|---|
| **A** | Promote `mask` to a shared module | Standalone `mask` module; gateway imports it. Fully verifiable: `go test ./...` in both modules. |
| **B** | WireGuardKit integration | Re-add `wireguard-apple` submodule (pin `1.0.16-27`), wire WireGuardKit via SPM, add the Go build phase producing `libwg-go.a`, plain WireGuard. Verifiable: unsigned device compile+link (`xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO`). |
| **C** | `MaskBind` + `wgSetStealthKey` | Bridge patch: `MaskBind` (using shared `mask`) + the key-setting export. Verifiable: a Go integration test on the Mac driving MaskBind ↔ real gateway ↔ echo upstream, plus device compile of the patched bridge. |
| **D** | iOS app + extension wiring | `.conf` + `[Stealth]` import, App Group storage, `WireGuardAdapter` start, `wgSetStealthKey` call, connect/disconnect/status UI. Verifiable: parser unit tests + device compile; the real handshake is on-device (the user). |

**Milestone:** after D, a successful WireGuard handshake from the app on a
physical iPhone (over a fingerprinting carrier) to the RB5009 WireGuard endpoint
through the Mac-hosted gateway.

## 7. Testability summary

- **A, C**: the masking layer is proven on the Mac with no device (unit tests +
  a Go round-trip integration test through the actual gateway code).
- **B, C, D**: compile/link verified for a real device (unsigned), so the Go
  bridge build and the extension build are green before any on-device run.
- **Only** WireGuard's real handshake crypto over this transport requires the
  device + the running gateway + the WireGuard server — that is the user's step.

## 8. Maintainability

We keep a small patch set on the vendored `wireguard-apple` submodule (the
`MaskBind`, the `wgSetStealthKey` export, the one-line device-creation change, and
the bridge `go.mod` `require`/`replace` for the shared `mask` module). Re-applied
on any upstream bump. This is the accepted cost of production obfuscated
WireGuard, and the patch is deliberately minimal to keep re-application cheap.

## 9. Out of scope (this phase)

- Bumping wireguard-go to the 2026 engine (separate later performance upgrade).
- QUIC/DNS/TCP transports (later, behind the same masking seam).
- Automatic transport fallback.
- Multiple profiles, accounts, analytics — still explicitly excluded.
