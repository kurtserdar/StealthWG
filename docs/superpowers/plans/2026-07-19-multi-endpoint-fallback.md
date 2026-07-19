# Multi-endpoint Fallback + Transport Interface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a profile list several gateway endpoints and have the client try them in order until a WireGuard handshake succeeds (A); extract an `Obfuscator` interface in `wgbind` so the masking bind is transport-generic (C).

**Architecture:** C is a Go seam (`Obfuscator`) that `mask.Codec` already satisfies. A adds an ordered endpoint list to `StealthProfile`, pure fallback decision logic in `Shared/StealthFallback.swift`, and a poll/`update` loop in `PacketTunnelProvider` that re-points the peer endpoint on handshake timeout. The standalone bundle gains a second relay on UDP 443.

**Tech Stack:** Go (wgbind), Swift/SwiftUI, WireGuardKit (`WireGuardAdapter.update`/`getRuntimeConfiguration`), NetworkExtension, Docker Compose.

## Global Constraints

- Code comments in English.
- Go: `go test ./...` in `wgbind` (and `mask`) must stay green.
- Swift pure logic tested via `scripts/test-parser.sh` (swiftc). NE glue verified by unsigned device build: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build` (run `xcodegen generate` first if `project.yml` changed).
- `Obfuscator` = `Seal(wg []byte) ([]byte, error)` + `Open(wire []byte) ([]byte, error)`; `*mask.Codec` satisfies it unchanged, so `wgbind.New(bind, codec)` in the bridge patch stays valid.
- Profile format: `[Peer] Endpoint` = primary; `[Stealth] Endpoints = h:p, h:p` = ordered fallbacks. Effective list = `dedup([peerEndpoint] + stealthEndpoints)`.
- Per-endpoint handshake timeout default: 12 s. Fallback runs at initial connect / manual reconnect only.
- Verified WireGuardKit APIs: `TunnelConfiguration(name:interface:peers:)`, `PeerConfiguration.endpoint: Endpoint?` (mutable), `Endpoint(from: String)` (failable), `WireGuardAdapter.update(tunnelConfiguration:completionHandler:)`, `getRuntimeConfiguration(completionHandler: (String?) -> Void)` (UAPI text with `last_handshake_time_sec=`).

## File Structure

- `wgbind/mask_bind.go` — add `Obfuscator`, make bind depend on it (Task 1).
- `wgbind/mask_bind_test.go` — genericity test (Task 1).
- `Shared/StealthProfile.swift` — `endpoints` + parse/serialize (Task 2).
- `Shared/StealthFallback.swift` — pure fallback logic (Task 3).
- `Tests/StealthProfileTests.swift` — endpoint + fallback checks (Tasks 2, 3).
- `scripts/test-parser.sh` — add `StealthFallback.swift` to compile line (Task 3).
- `App/TunnelManager.swift` — store/read `endpoints` (Task 4).
- `Tunnel/PacketTunnelProvider.swift` — poll/update fallback loop (Task 5).
- `deploy/standalone/docker-compose.yml`, `docs/deploy-gateway.md` — 443 relay + docs (Task 6).

---

### Task 1: `Obfuscator` interface in `wgbind`

**Files:**
- Modify: `wgbind/mask_bind.go`
- Modify: `wgbind/mask_bind_test.go`

**Interfaces:**
- Produces: `type Obfuscator interface { Seal([]byte) ([]byte, error); Open([]byte) ([]byte, error) }`; `New(inner conn.Bind, obf Obfuscator) *MaskBind`.

- [ ] **Step 1: Write the failing test**

Add to `wgbind/mask_bind_test.go`:

```go
// identityObf is a trivial Obfuscator (no transform) proving the bind is generic
// over the interface, not tied to *mask.Codec.
type identityObf struct{}

func (identityObf) Seal(wg []byte) ([]byte, error)   { return append([]byte(nil), wg...), nil }
func (identityObf) Open(wire []byte) ([]byte, error) { return append([]byte(nil), wire...), nil }

func TestBindIsGenericOverObfuscator(t *testing.T) {
	var _ Obfuscator = (*mask.Codec)(nil)
	var _ Obfuscator = identityObf{}

	// Echo server that returns bytes unchanged; identity obfuscator round-trips.
	gw, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer gw.Close()
	go func() {
		buf := make([]byte, 65535)
		for {
			n, addr, err := gw.ReadFromUDP(buf)
			if err != nil {
				return
			}
			gw.WriteToUDP(buf[:n], addr)
		}
	}()

	mb := New(conn.NewStdNetBind(), identityObf{})
	fns, _, err := mb.Open(0)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer mb.Close()
	ep, err := mb.ParseEndpoint(gw.LocalAddr().String())
	if err != nil {
		t.Fatalf("ParseEndpoint: %v", err)
	}
	payload := []byte("generic bind payload")
	if err := mb.Send(payload, ep); err != nil {
		t.Fatalf("Send: %v", err)
	}
	buf := make([]byte, 65535)
	_ = gw.SetReadDeadline(time.Now().Add(time.Second))
	n, _, err := fns[0](buf)
	if err != nil {
		t.Fatalf("recv: %v", err)
	}
	if !bytes.Equal(buf[:n], payload) {
		t.Fatalf("round trip mismatch: %q", buf[:n])
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd wgbind && go test ./... -run TestBindIsGenericOverObfuscator`
Expected: FAIL — `undefined: Obfuscator` (compile error).

- [ ] **Step 3: Write minimal implementation**

In `wgbind/mask_bind.go`, add the interface and switch the bind's dependency:

Add after the imports:

```go
// Obfuscator transforms WireGuard datagrams to and from their on-wire form.
// mask.Codec satisfies it today; a future transport (e.g. QUIC) can provide
// another implementation. The seam fits per-datagram obfuscation; a streaming
// transport may need it revised.
type Obfuscator interface {
	Seal(wg []byte) ([]byte, error)   // outbound WG datagram -> wire bytes
	Open(wire []byte) ([]byte, error) // inbound wire bytes -> WG datagram
}
```

Change the struct and constructor:

```go
// MaskBind wraps an inner conn.Bind and applies an Obfuscator at the UDP
// I/O boundary.
type MaskBind struct {
	inner conn.Bind
	obf   Obfuscator
}

// New returns a conn.Bind that obfuscates traffic through inner using obf.
func New(inner conn.Bind, obf Obfuscator) *MaskBind {
	return &MaskBind{inner: inner, obf: obf}
}
```

Replace the two `b.codec.` uses: in `Open`'s wrapped function `b.codec.Open(scratch[:n])` → `b.obf.Open(scratch[:n])`; in `Send`, `b.codec.Seal(buf)` → `b.obf.Seal(buf)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd wgbind && go test ./...`
Expected: PASS — the new test plus the existing `MaskBind` round-trip tests (which pass a `*mask.Codec`, now via the interface).

- [ ] **Step 5: Commit**

```bash
git add wgbind/mask_bind.go wgbind/mask_bind_test.go
git commit -m "wgbind: depend on an Obfuscator interface, not *mask.Codec"
```

---

### Task 2: `StealthProfile.endpoints` (parse + serialize)

**Files:**
- Modify: `Shared/StealthProfile.swift`
- Modify: `Tests/StealthProfileTests.swift`

**Interfaces:**
- Produces: `let endpoints: [String]`; `init(wgQuickConfig:maskKey:endpoints:)` with `endpoints` defaulted to `[]`; `parse` populates it; `serialize` emits `[Stealth] Endpoints` when `endpoints.count > 1`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/StealthProfileTests.swift` inside `main()`, before the final `print`:

```swift
// endpoints: primary from [Peer] Endpoint plus [Stealth] Endpoints, ordered/deduped.
let multi = """
[Interface]
PrivateKey = aaaa

[Peer]
PublicKey = bbbb
Endpoint = gw.example.com:51819
AllowedIPs = 0.0.0.0/0

[Stealth]
MaskKey = kkkk
Endpoints = gw.example.com:51819, gw.example.com:443
"""
let pe = try! StealthProfile.parse(multi)
check(pe.endpoints == ["gw.example.com:51819", "gw.example.com:443"], "parses ordered deduped endpoints")

let single = try! StealthProfile.parse(full)
check(single.endpoints == ["1.2.3.4:51819"], "single endpoint from [Peer] only")

// serialize emits [Stealth] Endpoints when there is more than one; round-trips.
check(pe.serialize().contains("Endpoints = gw.example.com:51819, gw.example.com:443"), "serialize writes Endpoints")
let peRT = try! StealthProfile.parse(pe.serialize())
check(peRT.endpoints == pe.endpoints, "endpoints round-trip")
check(!single.serialize().contains("Endpoints ="), "no Endpoints line for a single endpoint")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test-parser.sh`
Expected: FAIL — `value of type 'StealthProfile' has no member 'endpoints'`.

- [ ] **Step 3: Write minimal implementation**

In `Shared/StealthProfile.swift`:

Add the stored property after `maskKey`:

```swift
    /// Ordered gateway endpoints to try (primary first). May be empty.
    let endpoints: [String]
```

Add an explicit init (keeps existing 2-arg call sites working via the default):

```swift
    init(wgQuickConfig: String, maskKey: String?, endpoints: [String] = []) {
        self.wgQuickConfig = wgQuickConfig
        self.maskKey = maskKey
        self.endpoints = endpoints
    }
```

In `parse`, capture the peer endpoint and the stealth endpoints. Add locals near `maskKey`:

```swift
        var peerEndpoint: String?
        var stealthEndpoints: [String] = []
```

Inside the loop, in the non-stealth branch (before `wgLines.append(line)`), capture the first `Endpoint`:

```swift
            if peerEndpoint == nil, let value = value(of: "Endpoint", in: trimmed) {
                peerEndpoint = value
            }
```

Inside the stealth branch (alongside the `MaskKey` capture):

```swift
                if let value = value(of: "Endpoints", in: trimmed) {
                    stealthEndpoints = value
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
```

Before the final `return`, build the ordered deduped list and pass it:

```swift
        var ordered: [String] = []
        for ep in ([peerEndpoint].compactMap { $0 } + stealthEndpoints) where !ordered.contains(ep) {
            ordered.append(ep)
        }
        return StealthProfile(wgQuickConfig: wgConfig, maskKey: maskKey, endpoints: ordered)
```

In `serialize`, emit the Endpoints line. Replace the masked branch so it appends Endpoints when there is more than one:

```swift
        if let maskKey {
            out += "\n\n[Stealth]\nMaskKey = \(maskKey)\n"
            if endpoints.count > 1 {
                out += "Endpoints = \(endpoints.joined(separator: ", "))\n"
            }
        } else {
            out += "\n"
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/test-parser.sh`
Expected: PASS — `ALL PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Shared/StealthProfile.swift Tests/StealthProfileTests.swift
git commit -m "StealthProfile: parse and serialize an ordered endpoint list"
```

---

### Task 3: Pure fallback logic (`Shared/StealthFallback.swift`)

**Files:**
- Create: `Shared/StealthFallback.swift`
- Modify: `scripts/test-parser.sh`
- Modify: `Tests/StealthProfileTests.swift`

**Interfaces:**
- Produces: `enum FallbackAction`; `struct FallbackPlan { decide(index:elapsed:handshaked:) }`; `func lastHandshakeSeconds(fromRuntimeConfig:) -> Int`.

- [ ] **Step 1: Add the file to the test compile line**

In `scripts/test-parser.sh`, add `Shared/StealthFallback.swift` to the `swiftc` sources:

```bash
swiftc -o "$BIN" \
    "$ROOT/Shared/StealthProfile.swift" \
    "$ROOT/Shared/StealthFallback.swift" \
    "$ROOT/Tests/StealthProfileTests.swift"
```

- [ ] **Step 2: Write the failing test**

Add to `Tests/StealthProfileTests.swift` inside `main()`, before the final `print`:

```swift
// FallbackPlan transitions.
let plan = FallbackPlan(endpointCount: 2, perEndpointTimeout: 12)
check(plan.decide(index: 0, elapsed: 3, handshaked: true) == .connected, "handshake -> connected")
check(plan.decide(index: 0, elapsed: 3, handshaked: false) == .keepWaiting, "within timeout -> keepWaiting")
check(plan.decide(index: 0, elapsed: 13, handshaked: false) == .tryNext(index: 1), "timeout -> tryNext")
check(plan.decide(index: 1, elapsed: 13, handshaked: false) == .exhausted, "last timeout -> exhausted")

// lastHandshakeSeconds parsing.
check(lastHandshakeSeconds(fromRuntimeConfig: "private_key=x\nlast_handshake_time_sec=1699999999\n") == 1699999999, "parses handshake secs")
check(lastHandshakeSeconds(fromRuntimeConfig: "last_handshake_time_sec=0\n") == 0, "zero handshake secs")
check(lastHandshakeSeconds(fromRuntimeConfig: "no handshake here") == 0, "absent -> 0")
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash scripts/test-parser.sh`
Expected: FAIL — `cannot find 'FallbackPlan' in scope` / `cannot find 'lastHandshakeSeconds'`.

- [ ] **Step 4: Write minimal implementation**

Create `Shared/StealthFallback.swift`:

```swift
import Foundation

/// What the fallback loop should do next for the current endpoint.
enum FallbackAction: Equatable {
    case connected
    case keepWaiting
    case tryNext(index: Int)
    case exhausted
}

/// Decides, from observed handshake state and elapsed time, whether to keep
/// waiting on the current endpoint, advance to the next, or stop. Pure logic so
/// it can be unit-tested off-device.
struct FallbackPlan {
    let endpointCount: Int
    let perEndpointTimeout: TimeInterval

    func decide(index: Int, elapsed: TimeInterval, handshaked: Bool) -> FallbackAction {
        if handshaked { return .connected }
        if elapsed < perEndpointTimeout { return .keepWaiting }
        let next = index + 1
        return next < endpointCount ? .tryNext(index: next) : .exhausted
    }
}

/// Parses `last_handshake_time_sec=<n>` from a WireGuard runtime configuration
/// (UAPI text). Returns 0 when absent.
func lastHandshakeSeconds(fromRuntimeConfig text: String) -> Int {
    for line in text.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("last_handshake_time_sec=") {
            let value = trimmed.dropFirst("last_handshake_time_sec=".count)
            return Int(value) ?? 0
        }
    }
    return 0
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash scripts/test-parser.sh`
Expected: PASS — `ALL PASSED`.

- [ ] **Step 6: Commit**

```bash
git add Shared/StealthFallback.swift scripts/test-parser.sh Tests/StealthProfileTests.swift
git commit -m "Add pure fallback decision logic + handshake parsing with tests"
```

---

### Task 4: Store/read endpoints in `TunnelManager`

**Files:**
- Modify: `App/TunnelManager.swift`

**Interfaces:**
- Consumes: `StealthProfile.endpoints`, `serialize()`.

- [ ] **Step 1: Store endpoints on import**

In `App/TunnelManager.swift` `importProfile`, after setting `wgQuickConfig`, add endpoints to the provider configuration:

```swift
            var providerConfiguration: [String: Any] = ["wgQuickConfig": profile.wgQuickConfig]
            if let maskKey = profile.maskKey {
                providerConfiguration["maskKey"] = maskKey
            }
            if !profile.endpoints.isEmpty {
                providerConfiguration["endpoints"] = profile.endpoints
            }
```

- [ ] **Step 2: Reconstruct endpoints for export**

In `currentProfileText()`, read endpoints back and pass them to the initializer:

```swift
        let maskKey = proto.providerConfiguration?["maskKey"] as? String
        let endpoints = proto.providerConfiguration?["endpoints"] as? [String] ?? []
        return StealthProfile(wgQuickConfig: config, maskKey: maskKey, endpoints: endpoints).serialize()
```

- [ ] **Step 3: Commit**

```bash
git add App/TunnelManager.swift
git commit -m "TunnelManager: persist and restore the endpoint list"
```

---

### Task 5: Fallback poll/update loop in `PacketTunnelProvider`

**Files:**
- Modify: `Tunnel/PacketTunnelProvider.swift`

**Interfaces:**
- Consumes: `FallbackPlan`, `lastHandshakeSeconds`, `providerConfiguration["endpoints"]`, `WireGuardAdapter.update`/`getRuntimeConfiguration`, `TunnelConfiguration`/`PeerConfiguration`/`Endpoint`.

- [ ] **Step 1: Add fallback state and start the loop after adapter start**

Replace the body of `PacketTunnelProvider` with the version below (adds state, starts polling only when >1 endpoint):

```swift
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var adapter = WireGuardAdapter(with: self) { _, message in
        NSLog("[StealthWG] %@", message)
    }

    private let pollQueue = DispatchQueue(label: "com.stealthwg.fallback")
    private var pollTimer: DispatchSourceTimer?
    private var plan: FallbackPlan?
    private var endpoints: [String] = []
    private var currentIndex = 0
    private var endpointStart = Date()
    private var baseConfiguration: TunnelConfiguration?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard
            let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let providerConfiguration = proto.providerConfiguration,
            let wgQuickConfig = providerConfiguration["wgQuickConfig"] as? String
        else {
            completionHandler(PacketTunnelProviderError.missingConfiguration)
            return
        }

        let tunnelConfiguration: TunnelConfiguration
        do {
            tunnelConfiguration = try TunnelConfiguration(fromWgQuickConfig: wgQuickConfig)
        } catch {
            completionHandler(PacketTunnelProviderError.invalidConfiguration(error))
            return
        }
        baseConfiguration = tunnelConfiguration
        endpoints = providerConfiguration["endpoints"] as? [String] ?? []

        let maskKey = (providerConfiguration["maskKey"] as? String) ?? ""
        if wgSetStealthKey(maskKey) != 0 {
            completionHandler(PacketTunnelProviderError.invalidMaskKey)
            return
        }

        adapter.start(tunnelConfiguration: tunnelConfiguration) { [weak self] adapterError in
            if adapterError == nil { self?.startFallbackPolling() }
            completionHandler(adapterError)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        stopFallbackPolling()
        adapter.stop { _ in completionHandler() }
    }

    // MARK: - Endpoint fallback

    private func startFallbackPolling() {
        pollQueue.async { [weak self] in
            guard let self, self.endpoints.count > 1 else { return }
            self.plan = FallbackPlan(endpointCount: self.endpoints.count, perEndpointTimeout: 12)
            self.currentIndex = 0
            self.endpointStart = Date()
            let timer = DispatchSource.makeTimerSource(queue: self.pollQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.pollOnce() }
            self.pollTimer = timer
            timer.resume()
        }
    }

    private func stopFallbackPolling() {
        pollQueue.async { [weak self] in
            self?.pollTimer?.cancel()
            self?.pollTimer = nil
        }
    }

    private func pollOnce() {
        adapter.getRuntimeConfiguration { [weak self] runtime in
            self?.pollQueue.async {
                guard let self, let plan = self.plan else { return }
                let handshaked = (runtime.map { lastHandshakeSeconds(fromRuntimeConfig: $0) } ?? 0) > 0
                let elapsed = Date().timeIntervalSince(self.endpointStart)
                switch plan.decide(index: self.currentIndex, elapsed: elapsed, handshaked: handshaked) {
                case .connected:
                    NSLog("[StealthWG] handshake on endpoint %d (%@)", self.currentIndex, self.endpoints[self.currentIndex])
                    self.pollTimer?.cancel(); self.pollTimer = nil
                case .keepWaiting:
                    break
                case .tryNext(let i):
                    self.currentIndex = i
                    self.endpointStart = Date()
                    NSLog("[StealthWG] no handshake, trying endpoint %d (%@)", i, self.endpoints[i])
                    if let cfg = self.configuration(withEndpoint: self.endpoints[i]) {
                        self.adapter.update(tunnelConfiguration: cfg) { _ in }
                    }
                case .exhausted:
                    NSLog("[StealthWG] all endpoints exhausted; staying on last")
                    self.pollTimer?.cancel(); self.pollTimer = nil
                }
            }
        }
    }

    private func configuration(withEndpoint endpoint: String) -> TunnelConfiguration? {
        guard let base = baseConfiguration, let ep = Endpoint(from: endpoint) else { return nil }
        var peers = base.peers
        guard !peers.isEmpty else { return nil }
        peers[0].endpoint = ep
        return TunnelConfiguration(name: base.name, interface: base.interface, peers: peers)
    }
}

enum PacketTunnelProviderError: Error {
    case missingConfiguration
    case invalidConfiguration(Error)
    case invalidMaskKey
}
```

- [ ] **Step 2: Regenerate + unsigned device build**

Run: `xcodegen generate && export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" && xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Re-run pure tests**

Run: `bash scripts/test-parser.sh`
Expected: `ALL PASSED`.

- [ ] **Step 4: Commit**

```bash
git add Tunnel/PacketTunnelProvider.swift
git commit -m "PacketTunnelProvider: try endpoints in order until a handshake"
```

---

### Task 6: Second relay on UDP 443 (bundle + docs)

**Files:**
- Modify: `deploy/standalone/docker-compose.yml`
- Modify: `docs/deploy-gateway.md`

**Interfaces:**
- Consumes: the existing gateway image and the shared `/data/psk`.

- [ ] **Step 1: Add the 443 relay service**

In `deploy/standalone/docker-compose.yml`, add a second gateway service after `gateway`:

```yaml
  gateway443:
    image: ghcr.io/kurtserdar/stealthwg-gateway:latest
    restart: unless-stopped
    depends_on:
      - wg
    ports:
      - "443:51819/udp"
    environment:
      STEALTHWG_UPSTREAM: "wg:51820"
      STEALTHWG_PSK_FILE: "/data/psk"
    volumes:
      - ./data:/data:ro
```

- [ ] **Step 2: Document the fallback endpoint list**

In `docs/deploy-gateway.md`, in the "Standalone bundle" section, add after the `docker compose up -d` block:

```markdown
The bundle also exposes the relay on UDP 443. To use both (so the client falls
back to 443 when 51819 is blocked), list both in the profile's `[Stealth]`
section:

```
[Stealth]
MaskKey = <PSK>
Endpoints = <PUBLIC_HOST>:51819, <PUBLIC_HOST>:443
```

The client tries them in order and stays on the first that completes a handshake.
```

- [ ] **Step 3: Validate compose**

Run: `cd deploy/standalone && PUBLIC_HOST=x docker compose config -q && echo OK`
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add deploy/standalone/docker-compose.yml docs/deploy-gateway.md
git commit -m "Standalone: expose relay on UDP 443 for endpoint fallback + docs"
```

---

## Self-Review

**Spec coverage:**
- C: `Obfuscator` interface + bind depends on it, `*mask.Codec` unchanged → Task 1. ✓
- A profile format (`[Stealth] Endpoints`) + `endpoints` parse/serialize/round-trip → Task 2. ✓
- Pure fallback logic (`FallbackPlan`, `lastHandshakeSeconds`) + tests → Task 3. ✓
- Store/restore endpoints → Task 4. ✓
- NE poll/update loop, connect-only, timeout 12 s → Task 5. ✓
- 443 relay + docs → Task 6. ✓
- Testing (go test, swiftc harness, device build) → Tasks 1–5. ✓

**Placeholder scan:** No TODOs/TBDs; every code step is concrete.

**Type/name consistency:** `Obfuscator.Seal/Open` match `mask.Codec` (verified). `endpoints`, `FallbackPlan(endpointCount:perEndpointTimeout:)`, `decide(index:elapsed:handshaked:)`, `FallbackAction` cases, `lastHandshakeSeconds(fromRuntimeConfig:)` are used identically across Tasks 3–5. `TunnelConfiguration(name:interface:peers:)`, `PeerConfiguration.endpoint`, `Endpoint(from:)`, `adapter.update`/`getRuntimeConfiguration` match the verified WireGuardKit APIs. `providerConfiguration["endpoints"]` written in Task 4 and read in Task 5 use the same `[String]` type.
