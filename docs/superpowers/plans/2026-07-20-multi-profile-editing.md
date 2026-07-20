# Multiple Profiles + Structured Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. Apply frontend-design for views.

**Goal:** Manage several named profiles, switch between them, and edit an existing one in the pre-filled form — on both iOS and macOS via the shared layer.

**Architecture:** `TunnelManager` becomes multi-profile (a map of `NETunnelProviderManager`s keyed by a `profileID`). `ProfileDraft.from` reverse-parses a profile for editing. A new `ProfilesListView` plus name/edit additions to the existing views land on both platforms.

**Tech Stack:** Swift, SwiftUI, NetworkExtension.

## Global Constraints

- Code comments in English.
- Pure logic tested via `scripts/test-parser.sh`. UI verified by unsigned device builds: iOS `-scheme StealthWG -sdk iphoneos`, macOS `-scheme StealthWG-mac -sdk macosx`, both `CODE_SIGNING_ALLOWED=NO`.
- Only one active tunnel at a time (OS limit); connecting one stops the other.
- Imported profiles default their name to the endpoint host; scratch profiles take the form's Name field.
- New views go in `App/Views/` (shared by both targets); guard platform-only APIs via `App/Platform.swift` helpers.

## File Structure

- `Shared/ProfileDraft.swift` — add `from(_:)` + `defaultProfileName(for:)` (Task 1).
- `App/TunnelManager.swift` — multi-profile rewrite + `TunnelProfile` (Task 2).
- `App/Views/ProfileFormView.swift` — Name field + edit mode (Task 3).
- `App/Views/AddProfileView.swift` — default name + addProfile wiring (Task 4).
- `App/Views/ProfilesListView.swift` — new (Task 5).
- `App/Views/ProfileDetailView.swift`, `App/Views/ConnectionView.swift`, `App/ContentView.swift` — iOS wiring (Task 6).
- `macOS/MacMenuView.swift`, `macOS/StealthWGMacApp.swift` — macOS wiring (Task 7).

---

### Task 1: `ProfileDraft.from` + `defaultProfileName` (pure) + tests

**Files:** Modify `Shared/ProfileDraft.swift`, `Tests/StealthProfileTests.swift`.

**Interfaces:** `static func ProfileDraft.from(_ profile: StealthProfile) -> ProfileDraft`; `func defaultProfileName(for profile: StealthProfile) -> String`.

- [ ] **Step 1: Write the failing tests** — append to `Tests/StealthProfileTests.swift` before the final print:

```swift
// ProfileDraft.from reverses build() for our shape.
var src = ProfileDraft.defaults()
src.privateKey = "+CzRHZBUtXJnt/TL+e2kKcfR5Vsd9qC4Ij+Eg4kaRko="
src.serverPublicKey = "SRV"; src.endpoint = "gw.example.com:51819"; src.maskKey = "MK"
src.fallbackEndpoints = ["gw.example.com:443"]; src.keepalive = "25"; src.dns = "1.1.1.1"
let back = ProfileDraft.from(try! StealthProfile.parse(src.build()))
check(back.privateKey == src.privateKey, "from: private key")
check(back.serverPublicKey == "SRV", "from: server pubkey")
check(back.endpoint == "gw.example.com:51819", "from: endpoint")
check(back.fallbackEndpoints == ["gw.example.com:443"], "from: fallbacks")
check(back.maskKey == "MK", "from: mask key")
check(back.dns == "1.1.1.1", "from: dns")
check(defaultProfileName(for: try! StealthProfile.parse(src.build())) == "gw.example.com", "default name = endpoint host")
```

- [ ] **Step 2: Run to verify it fails** — `bash scripts/test-parser.sh` → `no member 'from'`.

- [ ] **Step 3: Implement** — add to `Shared/ProfileDraft.swift`:

```swift
extension ProfileDraft {
    /// Reverse of `build()` for our profile shape: line-scans the wg-quick config
    /// into editable fields so an existing profile can be edited in the form.
    static func from(_ profile: StealthProfile) -> ProfileDraft {
        func field(_ key: String) -> String {
            for line in profile.wgQuickConfig.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let eq = t.firstIndex(of: "=") else { continue }
                if t[..<eq].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame {
                    return t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                }
            }
            return ""
        }
        var d = ProfileDraft()
        d.privateKey = field("PrivateKey")
        d.address = field("Address")
        d.dns = field("DNS")
        d.mtu = field("MTU")
        d.serverPublicKey = field("PublicKey")
        d.allowedIPs = field("AllowedIPs")
        d.keepalive = field("PersistentKeepalive")
        d.presharedKey = field("PresharedKey")
        d.endpoint = profile.endpoints.first ?? field("Endpoint")
        d.fallbackEndpoints = Array(profile.endpoints.dropFirst())
        d.maskKey = profile.maskKey ?? ""
        return d
    }
}

/// Default display name for an imported profile: the endpoint host (no port).
func defaultProfileName(for profile: StealthProfile) -> String {
    guard let ep = profile.endpoints.first else { return "StealthWG" }
    if let colon = ep.lastIndex(of: ":") { return String(ep[..<colon]) }
    return ep
}
```

- [ ] **Step 4: Run to verify it passes** — `bash scripts/test-parser.sh` → `ALL PASSED`.

- [ ] **Step 5: Commit** — `git add Shared/ProfileDraft.swift Tests/StealthProfileTests.swift && git commit -m "ProfileDraft: reverse parser (from) + default name helper with tests"`

---

### Task 2: `TunnelManager` multi-profile rewrite

**Files:** Rewrite `App/TunnelManager.swift`.

**Interfaces (consumed by views):** `profiles: [TunnelProfile]`, `selectedID: String?`, `selectedProfile`, `statuses`, `status(of:)`, `connectedID`, `stats`, `lastError`, `load()`, `addProfile(name:raw:)`, `addProfile(_:name:)`, `updateProfile(id:name:raw:)`, `deleteProfile(id:)`, `connect(id:)`, `disconnect(id:)`, `profileText(id:)`.

- [ ] **Step 1: Rewrite the file**

```swift
import Foundation
import NetworkExtension

struct ConnectionStats: Equatable {
    var rxBytes: Int64; var txBytes: Int64
    var rxRate: Double; var txRate: Double
    var lastHandshakeSeconds: Int
    var activeEndpoint: String?; var isFallback: Bool
    var connectedSince: Date?
}

/// A saved StealthWG profile (one NETunnelProviderManager).
struct TunnelProfile: Identifiable, Equatable {
    let id: String
    let name: String
    let profile: StealthProfile
}

@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var profiles: [TunnelProfile] = []
    @Published private(set) var statuses: [String: NEVPNStatus] = [:]
    @Published private(set) var stats: ConnectionStats?
    @Published private(set) var lastError: String?
    @Published var selectedID: String?

    private var managers: [String: NETunnelProviderManager] = [:]
    private var observers: [NSObjectProtocol] = []
    private var statsTimer: Timer?
    private var lastSample: (rx: Int64, tx: Int64, at: Date)?
    private var connectedSince: Date?

    var selectedProfile: TunnelProfile? { profiles.first { $0.id == selectedID } }
    var connectedID: String? { profiles.first { isActive(statuses[$0.id] ?? .invalid) }?.id }
    func status(of id: String) -> NEVPNStatus { statuses[id] ?? .invalid }

    private func isActive(_ s: NEVPNStatus) -> Bool {
        s == .connected || s == .connecting || s == .reasserting
    }

    func load() async {
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            rebuild(from: all)
            selectedID = connectedID ?? profiles.first?.id
        } catch { lastError = error.localizedDescription }
    }

    private func rebuild(from all: [NETunnelProviderManager]) {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        managers.removeAll()
        var list: [TunnelProfile] = []
        for m in all {
            guard
                let proto = m.protocolConfiguration as? NETunnelProviderProtocol,
                let config = proto.providerConfiguration?["wgQuickConfig"] as? String,
                let parsed = try? StealthProfile.parse(assemble(proto))
            else { _ = config; continue }
            let id = (proto.providerConfiguration?["profileID"] as? String) ?? UUID().uuidString
            managers[id] = m
            statuses[id] = m.connection.status
            list.append(TunnelProfile(id: id, name: m.localizedDescription ?? "StealthWG", profile: parsed))
            observe(id: id, connection: m.connection)
        }
        profiles = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func assemble(_ proto: NETunnelProviderProtocol) -> String {
        let cfg = proto.providerConfiguration?["wgQuickConfig"] as? String ?? ""
        let mask = proto.providerConfiguration?["maskKey"] as? String
        let eps = proto.providerConfiguration?["endpoints"] as? [String] ?? []
        return StealthProfile(wgQuickConfig: cfg, maskKey: mask, endpoints: eps).serialize()
    }

    private func observe(id: String, connection: NEVPNConnection) {
        let o = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: connection, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.statuses[id] = connection.status
            self.handleStatusChange(id: id, status: connection.status)
        }
        observers.append(o)
    }

    // MARK: - CRUD

    func addProfile(_ draft: ProfileDraft, name: String) async {
        await addProfile(name: name, raw: draft.build())
    }

    func addProfile(name: String, raw: String) async {
        do {
            let profile = try StealthProfile.parse(raw)
            let m = NETunnelProviderManager()
            try await save(profile: profile, name: name, into: m, id: UUID().uuidString)
            await reloadAndSelect(preferName: name)
        } catch { lastError = describe(error) }
    }

    func updateProfile(id: String, name: String, raw: String) async {
        guard let m = managers[id] else { return }
        do {
            let profile = try StealthProfile.parse(raw)
            try await save(profile: profile, name: name, into: m, id: id)
            await reloadAndSelect(preferID: id)
        } catch { lastError = describe(error) }
    }

    private func save(profile: StealthProfile, name: String, into m: NETunnelProviderManager, id: String) async throws {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = TunnelConstants.tunnelBundleIdentifier
        proto.serverAddress = TunnelConstants.displayName
        var pc: [String: Any] = ["wgQuickConfig": profile.wgQuickConfig, "profileID": id]
        if let mask = profile.maskKey { pc["maskKey"] = mask }
        if !profile.endpoints.isEmpty { pc["endpoints"] = profile.endpoints }
        proto.providerConfiguration = pc
        m.protocolConfiguration = proto
        m.localizedDescription = name.isEmpty ? TunnelConstants.displayName : name
        m.isEnabled = true
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        lastError = nil
    }

    private func reloadAndSelect(preferID: String? = nil, preferName: String? = nil) async {
        if let all = try? await NETunnelProviderManager.loadAllFromPreferences() {
            rebuild(from: all)
        }
        if let preferID, profiles.contains(where: { $0.id == preferID }) { selectedID = preferID }
        else if let preferName, let match = profiles.first(where: { $0.name == preferName }) { selectedID = match.id }
        else if selectedProfile == nil { selectedID = connectedID ?? profiles.first?.id }
    }

    func deleteProfile(id: String) async {
        guard let m = managers[id] else { return }
        if connectedID == id { stopStatsPolling() }
        do { try await m.removeFromPreferences() } catch { lastError = error.localizedDescription }
        await reloadAndSelect()
    }

    // MARK: - Connect

    func connect(id: String) {
        // One active tunnel: stop any other first.
        if let other = connectedID, other != id { managers[other]?.connection.stopVPNTunnel() }
        do { try managers[id]?.connection.startVPNTunnel(); lastError = nil }
        catch { lastError = error.localizedDescription }
    }

    func disconnect(id: String) { managers[id]?.connection.stopVPNTunnel() }

    func profileText(id: String) -> String? {
        guard let m = managers[id], let proto = m.protocolConfiguration as? NETunnelProviderProtocol else { return nil }
        return assemble(proto)
    }

    // MARK: - Stats (for the connected tunnel)

    private func handleStatusChange(id: String, status: NEVPNStatus) {
        if status == .connected {
            if connectedSince == nil { connectedSince = Date() }
            startStatsPolling(id: id)
        } else if !isActive(status) {
            if connectedID == nil {
                stopStatsPolling(); connectedSince = nil; lastSample = nil; stats = nil
            }
        }
    }

    private func startStatsPolling(id: String) {
        guard statsTimer == nil else { return }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollStats(id: id)
        }
        pollStats(id: id)
    }
    private func stopStatsPolling() { statsTimer?.invalidate(); statsTimer = nil }

    private func pollStats(id: String) {
        guard let session = managers[id]?.connection as? NETunnelProviderSession else { return }
        do {
            try session.sendProviderMessage(Data("stats".utf8)) { [weak self] response in
                guard let response,
                      let obj = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else { return }
                let parsed = parseRuntimeStats(obj["runtime"] as? String ?? "")
                let ep = obj["activeEndpoint"] as? String
                let fb = obj["isFallback"] as? Bool ?? false
                Task { @MainActor in self?.updateStats(parsed, activeEndpoint: ep, isFallback: fb) }
            }
        } catch {}
    }

    private func updateStats(_ p: RuntimeStats, activeEndpoint: String?, isFallback: Bool) {
        let now = Date(); var rx = 0.0; var tx = 0.0
        if let last = lastSample {
            let dt = now.timeIntervalSince(last.at)
            if dt > 0 { rx = max(0, Double(p.rxBytes - last.rx) / dt); tx = max(0, Double(p.txBytes - last.tx) / dt) }
        }
        lastSample = (p.rxBytes, p.txBytes, now)
        stats = ConnectionStats(rxBytes: p.rxBytes, txBytes: p.txBytes, rxRate: rx, txRate: tx,
                                lastHandshakeSeconds: p.lastHandshakeSeconds,
                                activeEndpoint: activeEndpoint, isFallback: isFallback, connectedSince: connectedSince)
    }

    private func describe(_ error: Error) -> String {
        if case StealthProfile.ParseError.emptyConfiguration = error {
            return "The profile is empty or missing an [Interface] section."
        }
        return error.localizedDescription
    }
}
```

- [ ] **Step 2: Commit (compiles with view changes in later tasks; build in Task 8)** — `git add App/TunnelManager.swift && git commit -m "TunnelManager: multi-profile model (managers keyed by profileID)"`

---

### Task 3: `ProfileFormView` — Name field + edit mode

**Files:** Modify `App/Views/ProfileFormView.swift`.

- [ ] **Step 1:** Add `let editing: TunnelProfile?` (default nil) and `@State private var name`. Initialise from `editing` (name + `ProfileDraft.from(editing.profile)`), else empty draft + empty name. Add a **Name** `DraftField` at the top. On **Save**: if `editing != nil` call `updateProfile(id: editing.id, name: name, raw: draft.build())`, else `addProfile(draft, name: nameOrDefault)`. `canSave` also requires a non-empty name.

- [ ] **Step 2: Commit** — `git commit -am "ProfileFormView: name field + edit existing profile"`

---

### Task 4: `AddProfileView` — default name on import

**Files:** Modify `App/Views/AddProfileView.swift`.

- [ ] **Step 1:** Replace `tunnelManager.importProfile(text)` calls with: parse → `let name = defaultProfileName(for: parsed)` → `tunnelManager.addProfile(name: name, raw: text)`. The scratch `NavigationLink` opens `ProfileFormView()` (no `editing`). Dismiss on success (profiles grew).

- [ ] **Step 2: Commit** — `git commit -am "AddProfileView: import creates a named profile (endpoint host default)"`

---

### Task 5: `ProfilesListView` (new)

**Files:** Create `App/Views/ProfilesListView.swift`.

- [ ] **Step 1:** A `List` over `tunnelManager.profiles`: each row shows name + first endpoint (monospace) + a teal "Connected" badge when `id == connectedID`. Tapping a row sets `selectedID` and dismisses (to the connection screen) or pushes `ProfileDetailView`. A toolbar `+` presents `AddProfileView(onComplete:)`. `.swipeActions` / `onDelete` → `deleteProfile(id:)`. Empty state prompts Add.

- [ ] **Step 2: Commit** — `git commit -am "Add ProfilesListView: list, select, add, delete profiles"`

---

### Task 6: iOS wiring (`ContentView`, `ConnectionView`, `ProfileDetailView`)

**Files:** Modify these three.

- [ ] **Step 1:** `ContentView`: empty when `profiles.isEmpty` (Add); else show `ConnectionView` for `selectedProfile`, with a toolbar/button opening `ProfilesListView` in a sheet. `ConnectionView`: bind to `selectedProfile`; `ConnectDial` uses `status(of: selectedID)`; connect → `connect(id: selectedID!)`, disconnect → `disconnect(id:)`; show the profile name; stats when that profile is `connectedID`. `ProfileDetailView`: take a `TunnelProfile`, show name, add **Edit** (`ProfileFormView(editing: profile)`), Show QR (`profileText(id:)`), Delete (`deleteProfile(id:)`), and Connect.

- [ ] **Step 2: Commit** — `git commit -am "iOS: wire multi-profile into ContentView/ConnectionView/ProfileDetailView"`

---

### Task 7: macOS wiring (`MacMenuView`, `StealthWGMacApp`)

**Files:** Modify these.

- [ ] **Step 1:** `MacMenuView`: show `selectedProfile?.name`, status via `status(of: selectedID)`, connect/disconnect the selected id; add a profile picker (Menu listing `profiles`, setting `selectedID`). `ManageWindow`: host `ProfilesListView` (empty state Add).

- [ ] **Step 2: Commit** — `git commit -am "macOS: wire multi-profile into the menu and manage window"`

---

### Task 8: Build both platforms + tests

- [ ] **Step 1:** `xcodegen generate`
- [ ] **Step 2:** iOS build → `** BUILD SUCCEEDED **`.
- [ ] **Step 3:** macOS build → `** BUILD SUCCEEDED **`.
- [ ] **Step 4:** `bash scripts/test-parser.sh` → `ALL PASSED`.
- [ ] **Step 5:** `git commit -am "Multi-profile: green iOS + macOS builds"` (if any fix-ups).

---

## Self-Review

- **Spec coverage:** multi-profile model (Task 2), reverse parser + default name (Task 1), form name+edit (Task 3), import naming (Task 4), profiles list (Task 5), iOS (Task 6) + macOS (Task 7) wiring, builds+tests (Task 8). ✓
- **Placeholder scan:** Tasks 3–7 describe concrete edits with the exact API from Task 2; no vague TODOs. View bodies are written during implementation against the Task 2 contract.
- **Type/name consistency:** all view call sites use the Task 2 API (`profiles`, `selectedID`, `status(of:)`, `connectedID`, `addProfile`, `updateProfile`, `deleteProfile`, `connect(id:)`, `disconnect(id:)`, `profileText(id:)`). `ProfileDraft.from`/`defaultProfileName` (Task 1) consumed by Tasks 3/4. `TunnelProfile` used across views.
