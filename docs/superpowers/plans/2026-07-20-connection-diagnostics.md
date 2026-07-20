# Connection Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Test server" screen that probes each of a profile's endpoints from the current network — a real QUIC/TLS reachability check for QUIC endpoints, an honest "needs tunnel / verified via live handshake" state for mask endpoints — with live status and copy.

**Architecture:** A pure `ConnectionDiagnostics` model (targets, status, live-status reducer, summary) in `Shared/`, an app-side `DiagnosticsRunner` (Network.framework) that probes concurrently, and a shared `DiagnosticsView`. No extension changes.

**Tech Stack:** Swift, SwiftUI, Network.framework (`NWConnection`, `NWProtocolQUIC`), `scripts/test-parser.sh` (assert-based pure tests).

## Global Constraints

- **App-side only:** no extension changes; works connected or disconnected.
- **Honest signals:** QUIC → real handshake probe; mask → `needsTunnel`, upgraded to `reachableViaTunnel` only when it is the live active endpoint with a recent handshake.
- **Self-signed TLS accepted** in the QUIC probe (WireGuard authenticates the peer, not TLS); ALPN `h3`.
- **Cross-platform:** shared model + view; `Clipboard`/`inlineNavTitle` from `App/Platform.swift`.
- **English code comments.** Pure logic covered by `scripts/test-parser.sh`; iOS + macOS device builds stay green.
- Reuses `parseEndpointTarget` (in `Shared/StealthFallback.swift`) and `StealthProfile`.

## File Structure

- `Shared/ConnectionDiagnostics.swift` — pure model + helpers (unit-tested).
- `App/DiagnosticsRunner.swift` — `ObservableObject`, Network.framework probing (app + macOS targets).
- `App/Views/DiagnosticsView.swift` — shared SwiftUI screen.
- `App/Views/ProfileDetailView.swift` — entry point row.
- `Tests/StealthProfileTests.swift` + `scripts/test-parser.sh` — unit tests.
- `project.yml` — add `App/DiagnosticsRunner.swift` to the macOS target's explicit source list.

---

### Task 1: `ConnectionDiagnostics` model + helpers (pure, tested)

**Files:**
- Create: `Shared/ConnectionDiagnostics.swift`
- Modify: `Tests/StealthProfileTests.swift`, `scripts/test-parser.sh`

**Interfaces:**
- Produces: `DiagnosticTarget`, `DiagnosticStatus`, `DiagnosticResult`, `diagnosticTargets(for:)`, `applyLiveStatus(_:activeEndpoint:handshakeRecent:)`, `diagnosticsSummary(_:)` — consumed by `DiagnosticsRunner` (Task 2) and `DiagnosticsView` (Task 3).

- [ ] **Step 1: Write `Shared/ConnectionDiagnostics.swift`**

```swift
import Foundation

/// One endpoint to probe, with its transport and split host/port.
struct DiagnosticTarget: Equatable {
    let hostPort: String
    let transport: String   // "mask" | "quic"

    /// Host part (everything before the last colon), or the whole string if none.
    var host: String {
        guard let i = hostPort.lastIndex(of: ":") else { return hostPort }
        return String(hostPort[..<i])
    }
    /// Port after the last colon, or 0 if absent/invalid.
    var port: Int {
        guard let i = hostPort.lastIndex(of: ":") else { return 0 }
        return Int(hostPort[hostPort.index(after: i)...]) ?? 0
    }
}

/// Outcome of probing one target.
enum DiagnosticStatus: Equatable {
    case pending
    case reachableQUIC(rttMillis: Int)
    case reachableViaTunnel
    case timeout
    case unreachable(String)
    case dnsFailed
    case needsTunnel

    /// SF Symbol for the row.
    var symbol: String {
        switch self {
        case .pending: return "circle.dotted"
        case .reachableQUIC, .reachableViaTunnel: return "checkmark.circle.fill"
        case .timeout: return "clock.badge.exclamationmark"
        case .unreachable: return "xmark.circle.fill"
        case .dnsFailed: return "questionmark.circle.fill"
        case .needsTunnel: return "info.circle"
        }
    }

    /// Short human label.
    var label: String {
        switch self {
        case .pending: return "Testing…"
        case .reachableQUIC(let rtt): return "Reachable · \(rtt) ms"
        case .reachableViaTunnel: return "Reachable (live tunnel)"
        case .timeout: return "Timed out"
        case .unreachable(let reason): return "Unreachable · \(reason)"
        case .dnsFailed: return "Host not found"
        case .needsTunnel: return "Needs tunnel (mask)"
        }
    }
}

struct DiagnosticResult: Equatable, Identifiable {
    let target: DiagnosticTarget
    var status: DiagnosticStatus
    var id: String { target.hostPort }
}

/// Builds probe targets from a profile's endpoints (reuses parseEndpointTarget).
func diagnosticTargets(for profile: StealthProfile) -> [DiagnosticTarget] {
    profile.endpoints.map {
        let t = parseEndpointTarget($0, defaultTransport: profile.transport)
        return DiagnosticTarget(hostPort: t.hostPort, transport: t.transport)
    }
}

/// Upgrades a mask endpoint's `needsTunnel` to `reachableViaTunnel` when it is the
/// live active endpoint with a recent handshake. Pure.
func applyLiveStatus(_ results: [DiagnosticResult], activeEndpoint: String?, handshakeRecent: Bool) -> [DiagnosticResult] {
    guard let active = activeEndpoint, handshakeRecent else { return results }
    return results.map { r in
        if r.status == .needsTunnel, r.target.hostPort == active {
            var up = r; up.status = .reachableViaTunnel; return up
        }
        return r
    }
}

/// Human-readable multi-line summary for Copy.
func diagnosticsSummary(_ results: [DiagnosticResult]) -> String {
    results
        .map { "\($0.target.transport.uppercased())  \($0.target.hostPort)  —  \($0.status.label)" }
        .joined(separator: "\n")
}
```

- [ ] **Step 2: Write failing tests** — append inside `main()` in `Tests/StealthProfileTests.swift` before the final `print`:

```swift
        // Connection diagnostics: targets, host/port split, live-status upgrade.
        let diagRaw = """
        [Interface]
        PrivateKey = aaaa

        [Peer]
        PublicKey = bbbb
        Endpoint = gw.example.com:51819
        AllowedIPs = 0.0.0.0/0

        [Stealth]
        MaskKey = kkkk
        Endpoints = gw.example.com:51819, quic://gw.example.com:443
        """
        let diagProfile = try! StealthProfile.parse(diagRaw)
        let targets = diagnosticTargets(for: diagProfile)
        check(targets.map(\.hostPort) == ["gw.example.com:51819", "gw.example.com:443"], "targets from endpoints")
        check(targets[0].transport == "mask" && targets[1].transport == "quic", "target transports (default + scheme)")
        check(targets[1].host == "gw.example.com" && targets[1].port == 443, "host/port split on last colon")

        let seeded = targets.map { DiagnosticResult(target: $0, status: .needsTunnel) }
        let live = applyLiveStatus(seeded, activeEndpoint: "gw.example.com:51819", handshakeRecent: true)
        check(live[0].status == .reachableViaTunnel, "active mask endpoint upgraded via live tunnel")
        check(live[1].status == .needsTunnel, "non-active endpoint untouched")
        let noLive = applyLiveStatus(seeded, activeEndpoint: "gw.example.com:51819", handshakeRecent: false)
        check(noLive[0].status == .needsTunnel, "no upgrade without a recent handshake")
        let quicSeed = [DiagnosticResult(target: targets[1], status: .reachableQUIC(rttMillis: 42))]
        check(applyLiveStatus(quicSeed, activeEndpoint: "gw.example.com:443", handshakeRecent: true)[0].status == .reachableQUIC(rttMillis: 42), "QUIC result untouched by live status")

        check(DiagnosticStatus.reachableQUIC(rttMillis: 12).label == "Reachable · 12 ms", "quic label with rtt")
        check(DiagnosticStatus.needsTunnel.symbol == "info.circle", "needsTunnel symbol")
        check(diagnosticsSummary(live).contains("MASK  gw.example.com:51819  —  Reachable (live tunnel)"), "summary line format")
```

- [ ] **Step 3: Add the source to `scripts/test-parser.sh`** — add after `LogRingBuffer.swift`:

```sh
    "$ROOT/Shared/LogRingBuffer.swift" \
    "$ROOT/Shared/ConnectionDiagnostics.swift" \
    "$ROOT/Tests/StealthProfileTests.swift"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash scripts/test-parser.sh`
Expected: `ALL PASSED` (includes the new diagnostics checks).

- [ ] **Step 5: Commit**

```bash
git add Shared/ConnectionDiagnostics.swift Tests/StealthProfileTests.swift scripts/test-parser.sh
git commit -m "Add ConnectionDiagnostics: pure targets/status/live-status model for reachability tests"
```

---

### Task 2: `DiagnosticsRunner` (app-side Network.framework probing)

**Files:**
- Create: `App/DiagnosticsRunner.swift`
- Modify: `project.yml` (add the file to the macOS target's explicit sources)

**Interfaces:**
- Consumes: `DiagnosticTarget`, `DiagnosticResult`, `DiagnosticStatus`, `applyLiveStatus` (Task 1).
- Produces: `DiagnosticsRunner` `ObservableObject` with `@Published results`, `@Published isRunning`, `func run(for:activeEndpoint:handshakeRecent:)` — consumed by `DiagnosticsView` (Task 3).

- [ ] **Step 1: Write `App/DiagnosticsRunner.swift`**

```swift
import Foundation
import Network

/// Runs app-side reachability probes for a profile's endpoints. QUIC endpoints get
/// a real QUIC/TLS handshake probe; mask endpoints report `needsTunnel` (upgraded to
/// `reachableViaTunnel` by the live status). Nothing is persisted.
@MainActor
final class DiagnosticsRunner: ObservableObject {
    @Published private(set) var results: [DiagnosticResult] = []
    @Published private(set) var isRunning = false

    private let timeout: TimeInterval = 4
    private let queue = DispatchQueue(label: "com.stealthwg.diagnostics")

    /// Probes every target concurrently, then applies live status.
    func run(for profile: StealthProfile, activeEndpoint: String?, handshakeRecent: Bool) {
        let targets = diagnosticTargets(for: profile)
        results = targets.map { DiagnosticResult(target: $0, status: .pending) }
        isRunning = true

        let group = DispatchGroup()
        for (index, target) in targets.enumerated() {
            group.enter()
            probe(target) { [weak self] status in
                Task { @MainActor in
                    self?.update(index: index, status: status)
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.results = applyLiveStatus(self.results, activeEndpoint: activeEndpoint, handshakeRecent: handshakeRecent)
            self.isRunning = false
        }
    }

    private func update(index: Int, status: DiagnosticStatus) {
        guard results.indices.contains(index) else { return }
        results[index].status = status
    }

    /// Probes one target. Mask → needsTunnel (after DNS). QUIC → NWConnection with
    /// QUIC + ALPN h3, accepting the self-signed cert.
    private func probe(_ target: DiagnosticTarget, completion: @escaping (DiagnosticStatus) -> Void) {
        guard target.port > 0, let port = NWEndpoint.Port(rawValue: UInt16(target.port)) else {
            completion(.unreachable("bad port")); return
        }
        let host = NWEndpoint.Host(target.host)

        if target.transport != "quic" {
            // Mask/UDP is not directly probeable; report needsTunnel.
            completion(.needsTunnel)
            return
        }

        let quic = NWProtocolQUIC.Options(alpn: ["h3"])
        sec_protocol_options_set_verify_block(
            quic.securityProtocolOptions,
            { _, _, complete in complete(true) },   // WireGuard authenticates the peer, not TLS
            queue
        )
        let params = NWParameters(quic: quic)
        let conn = NWConnection(host: host, port: port, using: params)

        let start = Date()
        var finished = false
        let finish: (DiagnosticStatus) -> Void = { status in
            if finished { return }
            finished = true
            conn.cancel()
            completion(status)
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(.reachableQUIC(rttMillis: Int(Date().timeIntervalSince(start) * 1000)))
            case .failed(let error):
                finish(.unreachable(error.localizedDescription))
            case .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(.timeout) }
    }
}
```

- [ ] **Step 2: Add the file to the macOS target sources** in `project.yml` under `StealthWG-mac` (alongside the other explicit `App/*` paths):

```yaml
      - path: App/DiagnosticsRunner.swift
```

- [ ] **Step 3: Regenerate the project**

Run: `xcodegen generate`
Expected: `Created project at …`.

- [ ] **Step 4: Build the iOS app**

Run: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/claude-501/-Users-user-StealthWG/build-ios CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add App/DiagnosticsRunner.swift project.yml
git commit -m "Add DiagnosticsRunner: concurrent app-side QUIC reachability probes via Network.framework"
```

---

### Task 3: `DiagnosticsView` + entry point

**Files:**
- Create: `App/Views/DiagnosticsView.swift`
- Modify: `App/Views/ProfileDetailView.swift`

**Interfaces:**
- Consumes: `DiagnosticsRunner` (Task 2); `TunnelManager.stats`/`connectedID`; `DiagnosticStatus.symbol/label`, `diagnosticsSummary` (Task 1); `Clipboard`, `inlineNavTitle`.

- [ ] **Step 1: Write `App/Views/DiagnosticsView.swift`**

```swift
import SwiftUI

/// "Test server": probes a profile's endpoints for reachability and shows which
/// transport gets through. App-side; most accurate while disconnected.
struct DiagnosticsView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @StateObject private var runner = DiagnosticsRunner()
    let profile: StealthProfile

    var body: some View {
        List {
            Section {
                Button {
                    runner.run(
                        for: profile,
                        activeEndpoint: tunnelManager.stats?.activeEndpoint,
                        handshakeRecent: (tunnelManager.stats?.lastHandshakeSeconds ?? 0) > 0
                            && recentHandshake(tunnelManager.stats?.lastHandshakeSeconds))
                } label: {
                    Label(runner.isRunning ? "Testing…" : "Run test", systemImage: "bolt.horizontal.circle")
                }
                .disabled(runner.isRunning)
            } footer: {
                Text("QUIC endpoints are tested directly. Mask endpoints can only be confirmed by a live VPN handshake. Most accurate while disconnected.")
            }

            if !runner.results.isEmpty {
                Section("Endpoints") {
                    ForEach(runner.results) { result in
                        HStack(spacing: 10) {
                            Image(systemName: result.status.symbol).foregroundStyle(color(for: result.status))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.target.hostPort).font(.system(.footnote, design: .monospaced))
                                Text(result.status.label).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(result.target.transport.uppercased())
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Test server")
        .inlineNavTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Clipboard.copy(diagnosticsSummary(runner.results)) } label: {
                    Image(systemName: "doc.on.doc")
                }.disabled(runner.results.isEmpty)
            }
        }
    }

    private func recentHandshake(_ secs: Int?) -> Bool {
        guard let secs, secs > 0 else { return false }
        return Date().timeIntervalSince1970 - Double(secs) < 180
    }

    private func color(for status: DiagnosticStatus) -> Color {
        switch status {
        case .reachableQUIC, .reachableViaTunnel: return .green
        case .timeout, .unreachable, .dnsFailed: return .red
        case .needsTunnel, .pending: return .secondary
        }
    }
}
```

- [ ] **Step 2: Add the entry point** in `App/Views/ProfileDetailView.swift` — add a second row to the existing **Diagnostics** section:

```swift
                Section("Diagnostics") {
                    NavigationLink {
                        LogView()
                    } label: {
                        Label("Connection log", systemImage: "text.alignleft")
                    }
                    NavigationLink {
                        DiagnosticsView(profile: profile.profile)
                    } label: {
                        Label("Test reachability", systemImage: "bolt.horizontal.circle")
                    }
                }
```

- [ ] **Step 3: Regenerate + build iOS**

Run: `xcodegen generate && xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/claude-501/-Users-user-StealthWG/build-ios CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Build macOS**

Run: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG-mac -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath /tmp/claude-501/-Users-user-StealthWG/build-mac CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add App/Views/DiagnosticsView.swift App/Views/ProfileDetailView.swift
git commit -m "Add DiagnosticsView + Test reachability entry point in ProfileDetailView"
```

---

### Task 4: Full build + test sweep

**Files:** none (verification only).

- [ ] **Step 1:** `bash scripts/test-parser.sh` → `ALL PASSED`.
- [ ] **Step 2:** iOS device build → `** BUILD SUCCEEDED **`.
- [ ] **Step 3:** macOS device build → `** BUILD SUCCEEDED **`.

---

## Self-Review

- **Spec coverage:** model + helpers (T1), Network.framework prober (T2), view + entry point (T3), builds (T4). QUIC real probe + mask needsTunnel + live upgrade all in T1/T2. ✓
- **Placeholder scan:** every step has concrete code/commands; no TBD/TODO. ✓
- **Type consistency:** `DiagnosticTarget/DiagnosticStatus/DiagnosticResult` and `diagnosticTargets`/`applyLiveStatus`/`diagnosticsSummary` defined in T1 are used verbatim in T2/T3; `DiagnosticsRunner.run(for:activeEndpoint:handshakeRecent:)` matches the T3 call site; `.reachableQUIC`/`.needsTunnel`/`.reachableViaTunnel` cases match across prober, reducer, and view. ✓
- **Cross-platform:** `ConnectionDiagnostics` in `Shared/`; `DiagnosticsRunner`/`DiagnosticsView` in `App/` (added to the macOS target's explicit sources, like `TunnelManager.swift`); entry point in the shared `ProfileDetailView`. The extension never compiles the runner/view. ✓
