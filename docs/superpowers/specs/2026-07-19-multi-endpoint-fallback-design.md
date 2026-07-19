# Multi-endpoint fallback + transport interface — design

**Date:** 2026-07-19
**Status:** Approved, ready for implementation planning

## Goal

Two coordinated changes:

- **A — Multi-endpoint fallback:** a StealthWG profile can list several gateway
  endpoints (e.g. the same gateway on `:51819` and on `:443/udp`). At connect
  time the client tries them in order and stays on the first that completes a
  WireGuard handshake. This delivers real resilience against port/IP-based
  blocking now — running the mask transport on UDP 443 is the single
  highest-value fallback — without a second transport.
- **C — Transport interface groundwork:** extract a minimal `Obfuscator` seam in
  `wgbind` so the masking bind depends on an interface, not the concrete
  `*mask.Codec`. A future QUIC transport implements the seam and slots in
  cleanly. No new transport is built here.

QUIC (option B) is deliberately deferred until we observe a censor that defeats
mask-on-443; building it now would be speculative and, done half-heartedly, more
fingerprintable than the current masking.

## Background (current code)

- `wgbind/mask_bind.go` — `MaskBind` wraps `conn.Bind` and hardcodes `*mask.Codec`
  for `Seal`/`Open`. Constructed via `New(inner conn.Bind, codec *mask.Codec)`.
  The bridge patch `patches/wireguard-apple/0002-mask-bind.patch` calls
  `wgbind.New(...)`.
- `Shared/StealthProfile.swift` — `parse`/`serialize` split raw text into
  `wgQuickConfig` + `maskKey`. No endpoint parsing today.
- `Tunnel/PacketTunnelProvider.swift` — `startTunnel` parses one
  `TunnelConfiguration`, calls `wgSetStealthKey(maskKey)`, then
  `adapter.start(tunnelConfiguration:)`. Single endpoint, no fallback.
- `WireGuardAdapter` (verified) exposes `start(tunnelConfiguration:)`,
  `update(tunnelConfiguration:)` (re-point without a full restart), and
  `getRuntimeConfiguration(completionHandler:)` returning UAPI text containing
  `last_handshake_time_sec=<n>`.

## Part C — `Obfuscator` interface (Go)

Add to `wgbind`:

```go
// Obfuscator transforms WireGuard datagrams to and from their on-wire form.
type Obfuscator interface {
    Seal(wg []byte) ([]byte, error)   // outbound WG datagram -> wire bytes
    Open(wire []byte) ([]byte, error) // inbound wire bytes -> WG datagram
}
```

`mask.Codec` already has `Seal([]byte) ([]byte, error)` and
`Open([]byte) ([]byte, error)`, so it satisfies `Obfuscator` with no change.
Change `MaskBind`'s field from `*mask.Codec` to `Obfuscator`, and `New`'s
parameter from `*mask.Codec` to `Obfuscator`. Because `*mask.Codec` satisfies the
interface, the bridge patch's `wgbind.New(bind, codec)` call still compiles
unchanged. Existing `wgbind` tests keep passing (they pass a `*mask.Codec`).

Honesty note: this seam fits per-datagram obfuscation (mask). QUIC is
stateful/streaming and may need a richer seam; with a single implementor the
interface is cheap to revise then. We intentionally do not over-design for a
transport whose shape we don't yet know.

## Part A — multi-endpoint fallback

### Profile format

`[Peer] Endpoint` remains the standard, single primary endpoint. A new optional
`[Stealth] Endpoints = host:port, host:port` lists the ordered fallback list.
Standard WireGuard ignores the `[Stealth]` section. The effective ordered list is
`dedup([peerEndpoint] + stealthEndpoints)`, preserving order.

### `StealthProfile` changes

- Add `let endpoints: [String]` (ordered; may be empty when no endpoint is
  present). Add an explicit init with a default so existing 2-arg call sites keep
  working:

  ```swift
  init(wgQuickConfig: String, maskKey: String?, endpoints: [String] = [])
  ```

- `parse` captures the first `[Peer] Endpoint` value and the `[Stealth] Endpoints`
  comma list, and sets `endpoints = dedup([peerEndpoint] + stealthList)`.
- `serialize` writes `Endpoints = <joined by ", ">` under `[Stealth]` when
  `endpoints.count > 1`, so a QR/exported profile carries its fallback list and
  round-trips (`parse(serialize(x)) == x`).

### Pure fallback logic (`Shared/StealthFallback.swift`)

Device-independent, unit-tested via the swiftc harness:

```swift
enum FallbackAction: Equatable {
    case connected
    case keepWaiting
    case tryNext(index: Int)
    case exhausted
}

struct FallbackPlan {
    let endpointCount: Int
    let perEndpointTimeout: TimeInterval   // default 12

    func decide(index: Int, elapsed: TimeInterval, handshaked: Bool) -> FallbackAction {
        if handshaked { return .connected }
        if elapsed < perEndpointTimeout { return .keepWaiting }
        let next = index + 1
        return next < endpointCount ? .tryNext(index: next) : .exhausted
    }
}

// Parses `last_handshake_time_sec=<n>` from getRuntimeConfiguration output.
func lastHandshakeSeconds(fromRuntimeConfig text: String) -> Int
```

### NE wiring (`Tunnel/PacketTunnelProvider.swift`, device-only glue)

1. Read `endpoints` from `providerConfiguration["endpoints"]` (`[String]`). When
   empty or a single entry, behave exactly as today (no polling).
2. `adapter.start` with the base config (endpoint 0).
3. Poll `getRuntimeConfiguration` on a ~1 s repeating timer, tracking elapsed time
   on the current endpoint. Feed `(index, elapsed, handshaked)` to
   `FallbackPlan.decide`:
   - `.connected` → stop polling; the tunnel is up on this endpoint.
   - `.keepWaiting` → continue.
   - `.tryNext(i)` → build a `TunnelConfiguration` whose peer endpoint is
     `endpoints[i]`, call `adapter.update`, reset elapsed.
   - `.exhausted` → stop polling; leave the tunnel on the last endpoint (WireGuard
     keeps retrying) and log it.
4. Fallback runs only for the initial connect (and any manual reconnect). Re-running
   fallback after a mid-session drop is out of scope (MVP).

A helper rebuilds a `TunnelConfiguration` with a replaced peer endpoint
(`Endpoint(from:)`), leaving all other fields intact.

### `TunnelManager` changes

`importProfile` stores `providerConfiguration["endpoints"] = profile.endpoints`
alongside `wgQuickConfig`/`maskKey`. `currentProfileText()` reconstructs via
`StealthProfile(wgQuickConfig:maskKey:endpoints:).serialize()`.

## Gateway / bundle (so a 443 endpoint actually exists)

The gateway binary already listens on any `-listen` port. Add a second relay
service to `deploy/standalone/docker-compose.yml` publishing `443:51819/udp` to
the same `wg` upstream, and document listing both endpoints in the profile
(`[Stealth] Endpoints = <host>:51819, <host>:443`). This is a small compose +
docs addition; no gateway code change.

## Testing

- **Go (C):** adapt `wgbind/mask_bind_test.go` to exercise the bind through the
  `Obfuscator` interface; round-trip stays green. `go test ./...` in `wgbind`.
- **Swift pure logic (A):** `scripts/test-parser.sh` gains
  `Shared/StealthFallback.swift` on its compile line and new checks for
  `StealthProfile.endpoints` parse/serialize/round-trip, `FallbackPlan.decide`
  transitions, and `lastHandshakeSeconds` parsing.
- **NE glue (A):** the poll/update loop is device-only; verified by the unsigned
  device build (`xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO`) and a real
  on-device test by the user (connect where `:51819` is blocked but `:443` is not,
  observe fallback).

## Non-goals (YAGNI)

- QUIC or any second transport (deferred until evidence warrants).
- Re-running fallback after a mid-session disconnect.
- Per-endpoint mask keys.
- Racing endpoints in parallel (sequential is simpler and sufficient).

## Security notes

- No new secrets or persistence. The endpoint list is not sensitive on its own;
  the profile's sensitivity (private key, PSK) is unchanged.
- Trying UDP 443 does not weaken anything — it is the same masked WireGuard on a
  different port.
