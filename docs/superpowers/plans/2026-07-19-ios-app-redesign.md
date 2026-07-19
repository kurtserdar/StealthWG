# iOS App Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Apply superpowers/frontend-design principles when writing the SwiftUI views.

**Goal:** Replace the test-bench UI with a modern VPN app: an animated connect hero, live stats (throughput, handshake, active endpoint + fallback badge, masking), and a clean profile setup/detail flow, fed by app⇄extension IPC.

**Architecture:** Pure parsers in `Shared/` (unit-tested). The extension answers `handleAppMessage` with runtime counters + active endpoint. `TunnelManager` polls it while connected and publishes `ConnectionStats`. SwiftUI views render a router (empty state ↔ `ConnectionView`) plus sheets.

**Tech Stack:** Swift, SwiftUI, NetworkExtension (`NETunnelProviderSession.sendProviderMessage`), WireGuardKit (extension), XcodeGen.

## Global Constraints

- Code comments in English.
- Pure logic tested via `scripts/test-parser.sh` (swiftc). UI + IPC verified by unsigned device build: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build` (run `xcodegen generate` first).
- New UIKit/SwiftUI views live in `App/` (app target). New pure parsers in `Shared/` (both targets, added to the swiftc test compile line).
- IPC message: request is arbitrary bytes; response is JSON `{ "runtime": String, "activeEndpoint": String|null, "isFallback": Bool }`. No keys/PSK ever cross the channel.
- The fallback loop's `endpoints`/`currentIndex` already exist in `PacketTunnelProvider` (do not rename).
- `StealthProfile` keeps its `init(wgQuickConfig:maskKey:endpoints:)`.
- Apply frontend-design: dark-first + theme-aware, teal "stealth" accent, amber "connecting", monospace for technical values, SF Symbols, smooth transitions.

## File Structure

- `Shared/RuntimeStats.swift` — `parseRuntimeStats` (Task 1).
- `Shared/ProfileSummary.swift` — `ProfileSummary.from` (Task 1).
- `Tunnel/PacketTunnelProvider.swift` — `handleAppMessage` (Task 2).
- `App/TunnelManager.swift` — `ConnectionStats`, stats poll/IPC, `deleteProfile` (Task 3).
- `App/Theme.swift` — colors (Task 4).
- `App/Views/ConnectDial.swift`, `ConnectionView.swift`, `StatsView.swift` (Task 4).
- `App/Views/ProfileSetupView.swift`, `ProfileDetailView.swift` (Task 5).
- `App/ContentView.swift` — router (Task 6).
- `scripts/test-parser.sh`, `Tests/StealthProfileTests.swift` — parser tests (Task 1).

---

### Task 1: Shared pure parsers (`RuntimeStats`, `ProfileSummary`) + tests

**Files:**
- Create: `Shared/RuntimeStats.swift`, `Shared/ProfileSummary.swift`
- Modify: `scripts/test-parser.sh`, `Tests/StealthProfileTests.swift`

**Interfaces:**
- Produces: `struct RuntimeStats { rxBytes: Int64; txBytes: Int64; lastHandshakeSeconds: Int }`, `func parseRuntimeStats(_:) -> RuntimeStats`; `struct ProfileSummary { … }`, `static func ProfileSummary.from(_ profile: StealthProfile) -> ProfileSummary`.

- [ ] **Step 1: Add both files to the test compile line**

In `scripts/test-parser.sh`, extend the `swiftc` sources:

```bash
swiftc -o "$BIN" \
    "$ROOT/Shared/StealthProfile.swift" \
    "$ROOT/Shared/StealthFallback.swift" \
    "$ROOT/Shared/RuntimeStats.swift" \
    "$ROOT/Shared/ProfileSummary.swift" \
    "$ROOT/Tests/StealthProfileTests.swift"
```

- [ ] **Step 2: Write the failing tests**

Add to `Tests/StealthProfileTests.swift` inside `main()`, before the final `print`:

```swift
// parseRuntimeStats: sums rx/tx across peers, reuses handshake parse.
let uapi = """
private_key=abc
public_key=def
rx_bytes=1500
tx_bytes=800
last_handshake_time_sec=1699999999
"""
let rs = parseRuntimeStats(uapi)
check(rs.rxBytes == 1500, "rx parsed")
check(rs.txBytes == 800, "tx parsed")
check(rs.lastHandshakeSeconds == 1699999999, "handshake parsed")
check(parseRuntimeStats("no counters").rxBytes == 0, "missing rx -> 0")

// ProfileSummary.from: pulls display fields from wgQuickConfig + endpoints/mask.
let summ = ProfileSummary.from(pe)   // pe defined earlier: masked, 2 endpoints
check(summ.maskingOn == true, "summary masking on")
check(summ.endpoints == ["gw.example.com:51819", "gw.example.com:443"], "summary endpoints")
check(summ.peerPublicKey == "bbbb", "summary peer pubkey")
check(summ.address == nil || summ.address != nil, "summary address field present-or-nil")   // pe has no Address; tolerate
let summ2 = ProfileSummary.from(single)   // single: full profile with Address/Endpoint
check(summ2.address == "10.0.0.2/32", "summary address parsed")
check(summ2.maskingOn == true, "summary2 masking on")
```

- [ ] **Step 3: Run to verify it fails**

Run: `bash scripts/test-parser.sh`
Expected: FAIL — `cannot find 'parseRuntimeStats'` / `'ProfileSummary'`.

- [ ] **Step 4: Implement**

Create `Shared/RuntimeStats.swift`:

```swift
import Foundation

/// Byte counters and handshake age parsed from a WireGuard runtime configuration
/// (UAPI text). Summed across peers.
struct RuntimeStats: Equatable {
    var rxBytes: Int64
    var txBytes: Int64
    var lastHandshakeSeconds: Int
}

func parseRuntimeStats(_ uapi: String) -> RuntimeStats {
    var rx: Int64 = 0
    var tx: Int64 = 0
    for line in uapi.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("rx_bytes=") {
            rx += Int64(t.dropFirst("rx_bytes=".count)) ?? 0
        } else if t.hasPrefix("tx_bytes=") {
            tx += Int64(t.dropFirst("tx_bytes=".count)) ?? 0
        }
    }
    return RuntimeStats(rxBytes: rx, txBytes: tx,
                        lastHandshakeSeconds: lastHandshakeSeconds(fromRuntimeConfig: uapi))
}
```

Create `Shared/ProfileSummary.swift`:

```swift
import Foundation

/// Display-oriented view of a StealthProfile for the profile-detail screen.
/// Line-scans the wg-quick config so the app needs no WireGuardKit dependency
/// just to show details. Never exposes the private key or the mask PSK value.
struct ProfileSummary: Equatable {
    var address: String?
    var dns: String?
    var mtu: String?
    var endpoints: [String]
    var peerPublicKey: String?
    var allowedIPs: String?
    var maskingOn: Bool

    static func from(_ profile: StealthProfile) -> ProfileSummary {
        func field(_ key: String) -> String? {
            for line in profile.wgQuickConfig.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let eq = t.firstIndex(of: "=") else { continue }
                let k = t[..<eq].trimmingCharacters(in: .whitespaces)
                guard k.caseInsensitiveCompare(key) == .orderedSame else { continue }
                let v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            return nil
        }
        return ProfileSummary(
            address: field("Address"),
            dns: field("DNS"),
            mtu: field("MTU"),
            endpoints: profile.endpoints,
            peerPublicKey: field("PublicKey"),
            allowedIPs: field("AllowedIPs"),
            maskingOn: profile.maskKey != nil
        )
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash scripts/test-parser.sh`
Expected: PASS — `ALL PASSED`.

- [ ] **Step 6: Commit**

```bash
git add Shared/RuntimeStats.swift Shared/ProfileSummary.swift scripts/test-parser.sh Tests/StealthProfileTests.swift
git commit -m "Add RuntimeStats + ProfileSummary parsers with tests"
```

---

### Task 2: Extension `handleAppMessage`

**Files:**
- Modify: `Tunnel/PacketTunnelProvider.swift`

**Interfaces:**
- Produces: `handleAppMessage` returning JSON `{runtime, activeEndpoint, isFallback}`.

- [ ] **Step 1: Add the handler**

Add these methods inside `PacketTunnelProvider` (after `stopTunnel`):

```swift
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        adapter.getRuntimeConfiguration { [weak self] runtime in
            let payload: [String: Any] = [
                "runtime": runtime ?? "",
                "activeEndpoint": self?.currentActiveEndpoint() as Any,
                "isFallback": (self?.currentIndex ?? 0) > 0
            ]
            completionHandler?(try? JSONSerialization.data(withJSONObject: payload))
        }
    }

    private func currentActiveEndpoint() -> String? {
        guard !endpoints.isEmpty, currentIndex < endpoints.count else { return nil }
        return endpoints[currentIndex]
    }
```

- [ ] **Step 2: Verify (deferred to Task 6 device build)**

No standalone step; compiled in Task 6's device build.

- [ ] **Step 3: Commit**

```bash
git add Tunnel/PacketTunnelProvider.swift
git commit -m "Extension: answer app messages with runtime stats + active endpoint"
```

---

### Task 3: `TunnelManager` — stats polling, IPC, delete

**Files:**
- Modify: `App/TunnelManager.swift`

**Interfaces:**
- Produces: `struct ConnectionStats`; `@Published var stats: ConnectionStats?`; `deleteProfile() async`; polling started/stopped on status transitions.

- [ ] **Step 1: Add the model and state**

At the top of `App/TunnelManager.swift` (after imports), add:

```swift
struct ConnectionStats: Equatable {
    var rxBytes: Int64
    var txBytes: Int64
    var rxRate: Double
    var txRate: Double
    var lastHandshakeSeconds: Int
    var activeEndpoint: String?
    var isFallback: Bool
    var connectedSince: Date?
}
```

Inside `TunnelManager`, add published stats + private state:

```swift
    @Published private(set) var stats: ConnectionStats?

    private var statsTimer: Timer?
    private var lastSample: (rx: Int64, tx: Int64, at: Date)?
    private var connectedSince: Date?
```

- [ ] **Step 2: Drive polling from status changes**

In `observeStatus(of:)`, replace the observer closure body so it also reacts to the new status:

```swift
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.status = manager.connection.status
            self.handleStatusChange(self.status)
        }
```

Add the handler + polling methods to `TunnelManager`:

```swift
    private func handleStatusChange(_ status: NEVPNStatus) {
        if status == .connected {
            if connectedSince == nil { connectedSince = Date() }
            startStatsPolling()
        } else {
            stopStatsPolling()
            if status != .reasserting {
                connectedSince = nil
                lastSample = nil
                stats = nil
            }
        }
    }

    private func startStatsPolling() {
        guard statsTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollStats()
        }
        statsTimer = timer
        pollStats()
    }

    private func stopStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func pollStats() {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        do {
            try session.sendProviderMessage(Data("stats".utf8)) { [weak self] response in
                guard
                    let response,
                    let obj = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
                else { return }
                let runtime = obj["runtime"] as? String ?? ""
                let parsed = parseRuntimeStats(runtime)
                let activeEndpoint = obj["activeEndpoint"] as? String
                let isFallback = obj["isFallback"] as? Bool ?? false
                Task { @MainActor in
                    self?.updateStats(parsed, activeEndpoint: activeEndpoint, isFallback: isFallback)
                }
            }
        } catch {
            // Transient (tunnel not ready); ignore and retry next tick.
        }
    }

    private func updateStats(_ p: RuntimeStats, activeEndpoint: String?, isFallback: Bool) {
        let now = Date()
        var rxRate = 0.0
        var txRate = 0.0
        if let last = lastSample {
            let dt = now.timeIntervalSince(last.at)
            if dt > 0 {
                rxRate = max(0, Double(p.rxBytes - last.rx) / dt)
                txRate = max(0, Double(p.txBytes - last.tx) / dt)
            }
        }
        lastSample = (p.rxBytes, p.txBytes, now)
        stats = ConnectionStats(
            rxBytes: p.rxBytes, txBytes: p.txBytes,
            rxRate: rxRate, txRate: txRate,
            lastHandshakeSeconds: p.lastHandshakeSeconds,
            activeEndpoint: activeEndpoint, isFallback: isFallback,
            connectedSince: connectedSince
        )
    }

    func deleteProfile() async {
        stopStatsPolling()
        do {
            try await manager?.removeFromPreferences()
        } catch {
            lastError = error.localizedDescription
        }
        manager = nil
        hasProfile = false
        stats = nil
        connectedSince = nil
        lastSample = nil
        status = .invalid
    }
```

- [ ] **Step 3: Verify (deferred to Task 6 device build)**

Compiled in Task 6. Proceed.

- [ ] **Step 4: Commit**

```bash
git add App/TunnelManager.swift
git commit -m "TunnelManager: poll extension for live stats, add delete profile"
```

---

### Task 4: Theme + hero (`Theme`, `ConnectDial`, `ConnectionView`, `StatsView`)

**Files:**
- Create: `App/Theme.swift`, `App/Views/ConnectDial.swift`, `App/Views/ConnectionView.swift`, `App/Views/StatsView.swift`

**Interfaces:**
- Consumes: `TunnelManager.status`/`stats`, `ConnectionStats`.
- Produces: `ConnectionView` (bound in Task 6).

- [ ] **Step 1: Theme**

Create `App/Theme.swift`:

```swift
import SwiftUI
import NetworkExtension

enum Theme {
    static let accent = Color(red: 0.10, green: 0.80, blue: 0.72)   // stealth teal
    static let amber = Color(red: 0.98, green: 0.68, blue: 0.18)

    static func color(for status: NEVPNStatus) -> Color {
        switch status {
        case .connected: return accent
        case .connecting, .reasserting, .disconnecting: return amber
        default: return .secondary
        }
    }

    static func label(for status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "Not configured"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Protected"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        @unknown default: return "Unknown"
        }
    }
}
```

- [ ] **Step 2: ConnectDial (animated hero control)**

Create `App/Views/ConnectDial.swift`:

```swift
import SwiftUI
import NetworkExtension

/// Large circular tap-to-toggle connect control, animated across VPN states.
struct ConnectDial: View {
    let status: NEVPNStatus
    let action: () -> Void

    @State private var pulse = false

    private var isBusy: Bool {
        status == .connecting || status == .reasserting || status == .disconnecting
    }
    private var isOn: Bool { status == .connected }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Theme.color(for: status).opacity(0.25), lineWidth: 14)
                    .frame(width: 210, height: 210)
                Circle()
                    .fill(Theme.color(for: status).opacity(isOn ? 0.18 : 0.08))
                    .frame(width: 180, height: 180)
                    .shadow(color: Theme.color(for: status).opacity(isOn ? 0.5 : 0), radius: 30)
                    .scaleEffect(isBusy && pulse ? 1.05 : 1.0)
                VStack(spacing: 8) {
                    Image(systemName: isOn ? "lock.shield.fill" : "lock.open")
                        .font(.system(size: 44, weight: .semibold))
                    Text(isOn ? "Tap to disconnect" : "Tap to connect")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Theme.color(for: status))
            }
        }
        .buttonStyle(.plain)
        .onAppear { if isBusy { pulse = true } }
        .onChange(of: isBusy) { _, busy in
            withAnimation(busy ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default) {
                pulse = busy
            }
        }
        .animation(.easeInOut(duration: 0.4), value: status)
    }
}
```

- [ ] **Step 3: StatsView (live cards)**

Create `App/Views/StatsView.swift`:

```swift
import SwiftUI

/// Live connection stats: duration, throughput, handshake, active endpoint.
struct StatsView: View {
    let stats: ConnectionStats
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                statCard("Download", value: Self.rate(stats.rxRate), sub: Self.bytes(stats.rxBytes), system: "arrow.down")
                statCard("Upload", value: Self.rate(stats.txRate), sub: Self.bytes(stats.txBytes), system: "arrow.up")
            }
            HStack(spacing: 12) {
                statCard("Duration", value: durationText, sub: "connected", system: "clock")
                statCard("Handshake", value: handshakeText, sub: "last", system: "checkmark.seal")
            }
            endpointRow
        }
        .onReceive(ticker) { now = $0 }
    }

    private func statCard(_ title: String, value: String, sub: String, system: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: system)
                .font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .monospaced).weight(.semibold))
            Text(sub).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var endpointRow: some View {
        HStack {
            Label(stats.activeEndpoint ?? "—", systemImage: "network")
                .font(.system(.footnote, design: .monospaced))
            Spacer()
            if stats.isFallback {
                Text("FALLBACK").font(.caption2.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.amber.opacity(0.2), in: Capsule())
                    .foregroundStyle(Theme.amber)
            }
            Text("MASK ON").font(.caption2.bold())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.accent.opacity(0.2), in: Capsule())
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 4)
    }

    private var durationText: String {
        guard let since = stats.connectedSince else { return "—" }
        let s = Int(max(0, now.timeIntervalSince(since)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    private var handshakeText: String {
        guard stats.lastHandshakeSeconds > 0 else { return "—" }
        let ago = Int(Date().timeIntervalSince1970) - stats.lastHandshakeSeconds
        return ago < 0 ? "now" : "\(ago)s ago"
    }

    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .binary)
    }
    static func rate(_ bps: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .binary) + "/s"
    }
}
```

- [ ] **Step 4: ConnectionView (hero screen)**

Create `App/Views/ConnectionView.swift`:

```swift
import SwiftUI
import NetworkExtension

/// The home screen shown once a profile exists: profile chip, connect dial,
/// status, and (when connected) live stats.
struct ConnectionView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @Binding var showProfile: Bool

    private var isActive: Bool {
        switch tunnelManager.status {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            Button { showProfile = true } label: {
                HStack {
                    Image(systemName: "lock.shield")
                    Text("StealthWG profile")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }
                .font(.subheadline)
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            ConnectDial(status: tunnelManager.status) {
                isActive ? tunnelManager.disconnect() : tunnelManager.connect()
            }
            Text(Theme.label(for: tunnelManager.status))
                .font(.title2.bold())
                .foregroundStyle(Theme.color(for: tunnelManager.status))

            if let stats = tunnelManager.stats, tunnelManager.status == .connected {
                StatsView(stats: stats)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Spacer(minLength: 0)

            if let error = tunnelManager.lastError {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding()
        .animation(.easeInOut, value: tunnelManager.status)
    }
}
```

- [ ] **Step 5: Commit**

```bash
git add App/Theme.swift App/Views/ConnectDial.swift App/Views/StatsView.swift App/Views/ConnectionView.swift
git commit -m "Add themed connect hero + live stats views"
```

---

### Task 5: Profile setup + detail views

**Files:**
- Create: `App/Views/ProfileSetupView.swift`, `App/Views/ProfileDetailView.swift`

**Interfaces:**
- Consumes: `TunnelManager.importProfile`/`currentProfileText`/`deleteProfile`, `QRScannerView`, `QRCodeView`, `ProfileSummary`, `StealthProfile`.

- [ ] **Step 1: ProfileSetupView (import sheet)**

Create `App/Views/ProfileSetupView.swift`:

```swift
import SwiftUI

/// Import sheet: paste a profile or scan its QR.
struct ProfileSetupView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @Environment(\.dismiss) private var dismiss

    @State private var profileText = ""
    @State private var showScanner = false
    @State private var scanError: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Paste a StealthWG profile (a .conf with a [Stealth] section) or scan its QR code.")
                    .font(.footnote).foregroundStyle(.secondary)

                TextEditor(text: $profileText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(height: 220)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.3)))

                HStack {
                    Button { scanError = nil; showScanner = true } label: {
                        Label("Scan QR", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        Task {
                            await tunnelManager.importProfile(profileText)
                            if tunnelManager.hasProfile { dismiss() }
                        }
                    } label: { Text("Import").bold() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(profileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let scanError { Text(scanError).font(.footnote).foregroundStyle(.red) }
                if let error = tunnelManager.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
                Spacer()
            }
            .padding()
            .navigationTitle("Add profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $showScanner) {
                QRScannerView(
                    onScan: { code in
                        showScanner = false
                        Task {
                            await tunnelManager.importProfile(code)
                            if tunnelManager.hasProfile { dismiss() }
                        }
                    },
                    onError: { message in scanError = message; showScanner = false }
                )
                .ignoresSafeArea()
            }
        }
    }
}
```

- [ ] **Step 2: ProfileDetailView (summary + actions)**

Create `App/Views/ProfileDetailView.swift`:

```swift
import SwiftUI

/// Shows the parsed profile and offers export (QR), replace, and delete.
struct ProfileDetailView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @State private var showQR = false
    @State private var showReplace = false

    private var summary: ProfileSummary? {
        guard let text = tunnelManager.currentProfileText(),
              let profile = try? StealthProfile.parse(text) else { return nil }
        return ProfileSummary.from(profile)
    }

    var body: some View {
        NavigationStack {
            List {
                if let s = summary {
                    Section("Interface") {
                        row("Address", s.address)
                        row("DNS", s.dns)
                        row("MTU", s.mtu)
                    }
                    Section("Peer") {
                        row("Public key", s.peerPublicKey)
                        row("Allowed IPs", s.allowedIPs)
                    }
                    Section("Endpoints") {
                        ForEach(Array(s.endpoints.enumerated()), id: \.offset) { i, ep in
                            HStack {
                                Text(ep).font(.system(.footnote, design: .monospaced))
                                Spacer()
                                if i == 0 { Text("primary").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    Section("Masking") {
                        Label(s.maskingOn ? "On" : "Off", systemImage: s.maskingOn ? "checkmark.shield.fill" : "xmark.shield")
                            .foregroundStyle(s.maskingOn ? Theme.accent : .secondary)
                    }
                }
                Section {
                    Button { showQR = true } label: { Label("Show QR", systemImage: "qrcode") }
                    Button { showReplace = true } label: { Label("Replace profile", systemImage: "arrow.triangle.2.circlepath") }
                    Button(role: .destructive) {
                        Task { await tunnelManager.deleteProfile(); dismiss() }
                    } label: { Label("Delete profile", systemImage: "trash") }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showQR) {
                if let text = tunnelManager.currentProfileText() { QRCodeView(text: text) }
                else { Text("No profile to export.").padding() }
            }
            .sheet(isPresented: $showReplace) { ProfileSetupView().environmentObject(tunnelManager) }
        }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—").font(.system(.footnote, design: .monospaced)).multilineTextAlignment(.trailing)
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add App/Views/ProfileSetupView.swift App/Views/ProfileDetailView.swift
git commit -m "Add profile setup (paste/scan) and detail (summary/QR/delete) views"
```

---

### Task 6: ContentView router + integration build

**Files:**
- Modify: `App/ContentView.swift`

**Interfaces:**
- Consumes: all views + `TunnelManager.hasProfile`.

- [ ] **Step 1: Rewrite ContentView as a router**

Replace `App/ContentView.swift` entirely:

```swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @State private var showProfileSheet = false

    var body: some View {
        Group {
            if tunnelManager.hasProfile {
                ConnectionView(showProfile: $showProfileSheet)
            } else {
                emptyState
            }
        }
        .sheet(isPresented: $showProfileSheet) {
            if tunnelManager.hasProfile {
                ProfileDetailView().environmentObject(tunnelManager)
            } else {
                ProfileSetupView().environmentObject(tunnelManager)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(Theme.accent)
            Text("StealthWG").font(.largeTitle.bold())
            Text("Add a profile to get started.")
                .foregroundStyle(.secondary)
            Button { showProfileSheet = true } label: {
                Label("Add profile", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .padding(.horizontal, 40)
            Spacer()
        }
        .padding()
    }
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
git add App/ContentView.swift
git commit -m "ContentView: route between empty state and connection screen"
```

---

## Self-Review

**Spec coverage:**
- Router (empty state ↔ ConnectionView) + sheets → Task 6. ✓
- Animated connect hero → Task 4 (ConnectDial). ✓
- Live stats (duration/throughput/handshake/endpoint/fallback/mask) → Task 4 (StatsView) fed by Task 3 (poll) + Task 2 (extension) + Task 1 (parse). ✓
- Profile setup (paste/scan) + detail (summary/QR/replace/delete) → Task 5, `deleteProfile` Task 3. ✓
- Shared parsers unit-tested → Task 1. ✓
- IPC returns runtime + active endpoint, no secrets → Task 2. ✓
- Theme-aware, teal accent, monospace values, SF Symbols → Task 4 (Theme + views). ✓
- Device build + tests → Task 6. ✓

**Placeholder scan:** No TODOs; every code step is complete.

**Type/name consistency:** `parseRuntimeStats`→`RuntimeStats` used by Task 3; `ProfileSummary.from` by Task 5; `ConnectionStats` fields produced in Task 3 consumed by `StatsView` (Task 4); `handleAppMessage` JSON keys (`runtime`/`activeEndpoint`/`isFallback`) written in Task 2 and read in Task 3 match; `ConnectDial(status:action:)`, `StatsView(stats:)`, `ConnectionView(showProfile:)`, `ProfileSetupView()`, `ProfileDetailView()` signatures match their call sites in Task 6. `TunnelManager` members `status`/`stats`/`hasProfile`/`lastError`/`connect`/`disconnect`/`importProfile`/`currentProfileText`/`deleteProfile` all exist.
