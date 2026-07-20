# Shortcuts, Widgets & Control Center Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect/disconnect/toggle a profile without opening the app — App Intents (Siri/Shortcuts), three Home-Screen widgets (Shield, Status board, Quick connect), and a Control Center toggle — all driven by a shared app-group `WidgetSnapshot`.

**Architecture:** Shared App Intents call `NETunnelProviderManager`; the app publishes a `WidgetSnapshot` to the app group on every status/stats change and reloads timelines; a new WidgetKit extension renders the snapshot and its buttons invoke the intents.

**Tech Stack:** Swift, SwiftUI, AppIntents, WidgetKit, NetworkExtension, App Groups. `scripts/test-parser.sh` for pure tests.

## Global Constraints

- **App group** `group.com.stealthwg` (already in `App/App.entitlements`) shared app ↔ widget; widgets never poll the extension.
- **All surfaces share the same intents** (`ConnectVPNIntent`/`DisconnectVPNIntent`/`ToggleVPNIntent`).
- Identity: ghost accent = **teal (masked) / amber (masking) / coral (exposed)**; SF Rounded status, SF Mono data.
- Deployment: app iOS 16; **widget extension iOS 17** (interactive widgets); Control widget `@available(iOS 18)`.
- **English code comments.** Pure logic covered by `scripts/test-parser.sh`; iOS app + widget-extension builds stay green (device-only runtime verification noted).

## File Structure

- `Shared/WidgetSnapshot.swift` — snapshot model + `WidgetStore` (app-group I/O). Pure parts tested.
- `Shared/VPNIntents.swift` — App Intents + `ProfileEntity`/`ProfileQuery` + `AppShortcutsProvider` (app + widget targets).
- `App/TunnelManager.swift` — publish snapshot + last-selected id.
- `StealthWGWidgets/` — widget bundle, three widgets, control, entitlements, Info.
- `project.yml` — widget target + shared-source membership.
- `Tests/StealthProfileTests.swift` + `scripts/test-parser.sh` — snapshot unit tests.

---

### Task 1: `WidgetSnapshot` + `WidgetStore` (model + group store)

**Files:**
- Create: `Shared/WidgetSnapshot.swift`
- Modify: `Tests/StealthProfileTests.swift`, `scripts/test-parser.sh`

**Interfaces:**
- Produces: `WidgetSnapshot` (Codable), `WidgetSnapshot.State`, `.empty`, `statusLabel`, `accentName`; `WidgetStore.appGroup/load()/save(_:)` — consumed by intents (T2), TunnelManager (T3), widgets (T4).

- [ ] **Step 1: Write `Shared/WidgetSnapshot.swift`**

```swift
import Foundation

/// The state the widgets render, shared from the app via the app group.
struct WidgetSnapshot: Codable, Equatable {
    enum State: String, Codable { case masked, masking, exposed }

    var state: State = .exposed
    var profileName: String?
    var transport: String?          // "mask" | "quic"
    var endpoint: String?
    var rxRate: Double = 0
    var txRate: Double = 0
    var connectedSince: Date?
    var lastHandshakeSeconds: Int = 0

    static let empty = WidgetSnapshot()

    /// "Masked" | "Masking…" | "Exposed".
    var statusLabel: String {
        switch state {
        case .masked: return "Masked"
        case .masking: return "Masking…"
        case .exposed: return "Exposed"
        }
    }
    /// Accent token the widget views map to a Color.
    var accentName: String {
        switch state {
        case .masked: return "teal"
        case .masking: return "amber"
        case .exposed: return "coral"
        }
    }
}

/// Reads/writes the snapshot in the shared app group. Also stores the id of the
/// profile an intent should act on when none is specified.
enum WidgetStore {
    static let appGroup = "group.com.stealthwg"
    private static let snapshotKey = "widgetSnapshot"
    private static let selectedKey = "selectedProfileID"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func load() -> WidgetSnapshot {
        guard let data = defaults?.data(forKey: snapshotKey),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return .empty }
        return snap
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: snapshotKey)
    }

    static func selectedProfileID() -> String? { defaults?.string(forKey: selectedKey) }
    static func setSelectedProfileID(_ id: String?) { defaults?.set(id, forKey: selectedKey) }
}
```

- [ ] **Step 2: Write failing tests** — append inside `main()` in `Tests/StealthProfileTests.swift`:

```swift
        // WidgetSnapshot: labels/accents per state + Codable round-trip.
        check(WidgetSnapshot.empty.state == .exposed, "empty snapshot is exposed")
        check(WidgetSnapshot(state: .masked).statusLabel == "Masked" && WidgetSnapshot(state: .masked).accentName == "teal", "masked -> teal")
        check(WidgetSnapshot(state: .masking).statusLabel == "Masking…" && WidgetSnapshot(state: .masking).accentName == "amber", "masking -> amber")
        check(WidgetSnapshot(state: .exposed).accentName == "coral", "exposed -> coral")
        var snap = WidgetSnapshot(state: .masked, profileName: "Home", transport: "quic", endpoint: "gw:443", rxRate: 1200, txRate: 340, connectedSince: nil, lastHandshakeSeconds: 8)
        let round = try! JSONDecoder().decode(WidgetSnapshot.self, from: try! JSONEncoder().encode(snap))
        check(round == snap, "snapshot Codable round-trips")
```

- [ ] **Step 3: Add the source to `scripts/test-parser.sh`** (after `OnDemandRules.swift`):

```sh
    "$ROOT/Shared/OnDemandRules.swift" \
    "$ROOT/Shared/WidgetSnapshot.swift" \
    "$ROOT/Tests/StealthProfileTests.swift"
```

- [ ] **Step 4: Run tests**

Run: `bash scripts/test-parser.sh`
Expected: `ALL PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Shared/WidgetSnapshot.swift Tests/StealthProfileTests.swift scripts/test-parser.sh
git commit -m "Add WidgetSnapshot + WidgetStore: app-group state shared to widgets"
```

---

### Task 2: App Intents (`VPNIntents.swift`)

**Files:**
- Create: `Shared/VPNIntents.swift`
- Modify: `project.yml` (ensure the file is in both the iOS app and widget targets — it is under `Shared`, already in the app; the widget target added in Task 4 also includes `Shared`).

**Interfaces:**
- Consumes: `WidgetStore` (T1).
- Produces: `ConnectVPNIntent`, `DisconnectVPNIntent`, `ToggleVPNIntent`, `ProfileEntity`, `StealthShortcuts` — consumed by widgets (T4).

- [ ] **Step 1: Write `Shared/VPNIntents.swift`**

```swift
import AppIntents
import NetworkExtension

/// A StealthWG profile chooseable in Shortcuts / the Quick-connect widget.
struct ProfileEntity: AppEntity, Identifiable {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Profile"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = ProfileQuery()
}

struct ProfileQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ProfileEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [ProfileEntity] { try await all() }

    private func all() async throws -> [ProfileEntity] {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.compactMap { m in
            let pc = (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
            guard let id = pc?["profileID"] as? String else { return nil }
            return ProfileEntity(id: id, name: m.localizedDescription ?? "StealthWG")
        }
    }
}

enum VPNIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noProfile
    var localizedStringResource: LocalizedStringResource {
        switch self { case .noProfile: return "Add a profile in StealthWG first." }
    }
}

/// Loads the target manager: the named profile, else the last-selected one, else the first.
private func targetManager(_ profile: ProfileEntity?) async throws -> NETunnelProviderManager {
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()
    func id(_ m: NETunnelProviderManager) -> String? {
        ((m.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["profileID"] as? String)
    }
    if let pid = profile?.id ?? WidgetStore.selectedProfileID(),
       let m = managers.first(where: { id($0) == pid }) { return m }
    guard let first = managers.first else { throw VPNIntentError.noProfile }
    return first
}

struct ConnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect StealthWG"
    static var openAppWhenRun = false
    @Parameter(title: "Profile") var profile: ProfileEntity?

    func perform() async throws -> some IntentResult {
        let m = try await targetManager(profile)
        m.isEnabled = true
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        try (m.connection as? NETunnelProviderSession)?.startTunnel()
        return .result()
    }
}

struct DisconnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect StealthWG"
    static var openAppWhenRun = false
    @Parameter(title: "Profile") var profile: ProfileEntity?

    func perform() async throws -> some IntentResult {
        let m = try await targetManager(profile)
        m.connection.stopVPNTunnel()
        return .result()
    }
}

struct ToggleVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle StealthWG"
    static var openAppWhenRun = false
    @Parameter(title: "Profile") var profile: ProfileEntity?

    func perform() async throws -> some IntentResult {
        let m = try await targetManager(profile)
        switch m.connection.status {
        case .connected, .connecting, .reasserting:
            m.connection.stopVPNTunnel()
        default:
            m.isEnabled = true
            try await m.saveToPreferences()
            try await m.loadFromPreferences()
            try (m.connection as? NETunnelProviderSession)?.startTunnel()
        }
        return .result()
    }
}

struct StealthShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleVPNIntent(), phrases: ["Toggle \(.applicationName)"])
        AppShortcut(intent: ConnectVPNIntent(), phrases: ["Connect \(.applicationName)"])
        AppShortcut(intent: DisconnectVPNIntent(), phrases: ["Disconnect \(.applicationName)"])
    }
}
```

- [ ] **Step 2: Build the iOS app** (intents compile into the app target)

Run: `xcodegen generate && xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/claude-501/-Users-user-StealthWG/build-ios CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Shared/VPNIntents.swift
git commit -m "Add App Intents: Connect/Disconnect/Toggle + ProfileEntity + AppShortcuts"
```

---

### Task 3: TunnelManager publishes the snapshot

**Files:**
- Modify: `App/TunnelManager.swift`

**Interfaces:**
- Consumes: `WidgetSnapshot`, `WidgetStore` (T1).

- [ ] **Step 1: Import WidgetKit** at the top:

```swift
import WidgetKit
```

- [ ] **Step 2: Add `publishWidgetSnapshot()`** (near `updateStats`):

```swift
    /// Publishes the current state to the app group so widgets can render it, then
    /// reloads their timelines. Also records the selected profile for intents.
    private func publishWidgetSnapshot() {
        WidgetStore.setSelectedProfileID(connectedID ?? selectedID)
        let id = connectedID ?? selectedID
        let profile = profiles.first { $0.id == id }
        let status = status(of: id)

        let state: WidgetSnapshot.State
        switch status {
        case .connected: state = .masked
        case .connecting, .reasserting: state = .masking
        default: state = .exposed
        }

        let snap = WidgetSnapshot(
            state: state,
            profileName: profile?.name,
            transport: profile?.profile.transport,
            endpoint: stats?.activeEndpoint ?? profile?.profile.endpoints.first,
            rxRate: stats?.rxRate ?? 0,
            txRate: stats?.txRate ?? 0,
            connectedSince: stats?.connectedSince,
            lastHandshakeSeconds: stats?.lastHandshakeSeconds ?? 0
        )
        WidgetStore.save(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }
```

- [ ] **Step 3: Call it on status and stats changes.** In `handleStatusChange(...)` (status observer path) and at the end of `updateStats(...)`, add:

```swift
        publishWidgetSnapshot()
```

- [ ] **Step 4: Build the iOS app**

Run: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/claude-501/-Users-user-StealthWG/build-ios CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add App/TunnelManager.swift
git commit -m "TunnelManager: publish WidgetSnapshot to the app group on status/stats change"
```

---

### Task 4: Widget extension target + three widgets + Control

**Files:**
- Create: `StealthWGWidgets/StealthWGWidgetBundle.swift`, `StealthWGWidgets/Widgets.swift`, `StealthWGWidgets/WidgetTheme.swift`, `StealthWGWidgets/StealthWGWidgets.entitlements`, `StealthWGWidgets/Info.plist`
- Modify: `project.yml`

**Interfaces:**
- Consumes: `WidgetSnapshot`/`WidgetStore` (T1), `ProfileEntity`/intents (T2).

- [ ] **Step 1: Add the widget target to `project.yml`** (under `targets:`), plus embed it in the iOS app:

```yaml
  StealthWGWidgets:
    type: app-extension
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - StealthWGWidgets
      - Shared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.stealthwg.widgets
        PRODUCT_NAME: StealthWGWidgets
        CODE_SIGN_ENTITLEMENTS: StealthWGWidgets/StealthWGWidgets.entitlements
        INFOPLIST_FILE: StealthWGWidgets/Info.plist
        GENERATE_INFOPLIST_FILE: YES
    dependencies:
      - sdk: WidgetKit.framework
      - sdk: SwiftUI.framework
```
Add to the `StealthWG` (iOS app) `dependencies:` list:
```yaml
      - target: StealthWGWidgets
        embed: true
```

- [ ] **Step 2: Write `StealthWGWidgets/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.widgetkit-extension</string>
  </dict>
</dict>
</plist>
```

- [ ] **Step 3: Write `StealthWGWidgets/StealthWGWidgets.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>group.com.stealthwg</string>
  </array>
</dict>
</plist>
```

- [ ] **Step 4: Write `StealthWGWidgets/WidgetTheme.swift`** (shared identity colors + ghost)

```swift
import SwiftUI

enum WidgetTheme {
    static func accent(_ name: String) -> Color {
        switch name {
        case "teal": return Color(red: 0.22, green: 0.88, blue: 0.78)
        case "amber": return Color(red: 0.96, green: 0.70, blue: 0.29)
        default: return Color(red: 1.0, green: 0.42, blue: 0.44) // coral
        }
    }
}

/// The Wraith ghost, tinted by the current state.
struct GhostMark: View {
    var color: Color
    var filled: Bool = true
    var body: some View {
        GhostShape()
            .fill(filled ? color : .clear)
            .overlay(filled ? nil : GhostShape().stroke(color, lineWidth: 6))
            .overlay(EyesShape().fill(Color.black.opacity(filled ? 1 : 0)))
            .aspectRatio(120.0/130.0, contentMode: .fit)
    }
}

struct GhostShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x/120*w, y: r.minY + y/130*h) }
        var path = Path()
        path.move(to: p(60, 10))
        path.addCurve(to: p(18, 56), control1: p(34, 10), control2: p(18, 30))
        path.addLine(to: p(18, 104))
        path.addQuadCurve(to: p(39, 104), control: p(28.5, 116))
        path.addQuadCurve(to: p(60, 104), control: p(49.5, 116))
        path.addQuadCurve(to: p(81, 104), control: p(70.5, 116))
        path.addQuadCurve(to: p(102, 104), control: p(91.5, 116))
        path.addLine(to: p(102, 56))
        path.addCurve(to: p(60, 10), control1: p(102, 30), control2: p(86, 10))
        path.closeSubpath()
        return path
    }
}

struct EyesShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func e(_ cx: CGFloat, _ cy: CGFloat) -> CGRect {
            CGRect(x: r.minX + (cx-7)/120*w, y: r.minY + (cy-7)/130*h, width: 14/120*w, height: 14/130*h)
        }
        var path = Path()
        path.addEllipse(in: e(47, 54)); path.addEllipse(in: e(73, 54))
        return path
    }
}
```

- [ ] **Step 5: Write `StealthWGWidgets/Widgets.swift`** (timeline + the three widgets + control)

```swift
import WidgetKit
import SwiftUI
import AppIntents

struct SnapshotEntry: TimelineEntry { let date: Date; let snapshot: WidgetSnapshot }

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { .init(date: Date(), snapshot: .empty) }
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(.init(date: Date(), snapshot: WidgetStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetStore.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
    }
}

// MARK: Shield (small, toggle)
struct ShieldWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ShieldWidget", provider: SnapshotProvider()) { entry in
            ShieldView(snap: entry.snapshot).containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Shield")
        .description("Status and one-tap toggle.")
        .supportedFamilies([.systemSmall])
    }
}
struct ShieldView: View {
    let snap: WidgetSnapshot
    var body: some View {
        let c = WidgetTheme.accent(snap.accentName)
        VStack(alignment: .leading, spacing: 6) {
            HStack { GhostMark(color: c).frame(width: 22); Text("StealthWG").font(.system(.caption2, design: .rounded).weight(.bold)).foregroundStyle(.secondary); Spacer() }
            Spacer()
            Text(snap.statusLabel).font(.system(.title2, design: .rounded).weight(.heavy)).foregroundStyle(c)
            Text("\(snap.profileName ?? "No profile") · \((snap.transport ?? "mask").uppercased())")
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            Button(intent: ToggleVPNIntent()) {
                Text(snap.state == .exposed ? "Connect" : "Disconnect").font(.system(.caption2, design: .rounded).weight(.semibold))
            }.buttonStyle(.borderedProminent).tint(c)
        }
    }
}

// MARK: Status board (medium)
struct StatusBoardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StatusBoardWidget", provider: SnapshotProvider()) { entry in
            StatusBoardView(snap: entry.snapshot).containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Status board")
        .description("Live throughput and endpoint.")
        .supportedFamilies([.systemMedium])
    }
}
struct StatusBoardView: View {
    let snap: WidgetSnapshot
    private func rate(_ b: Double) -> String { b > 1_000_000 ? String(format: "%.1f MB/s", b/1_000_000) : String(format: "%.0f KB/s", b/1000) }
    var body: some View {
        let c = WidgetTheme.accent(snap.accentName)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                GhostMark(color: c).frame(width: 26)
                Text("StealthWG").font(.system(.subheadline, design: .rounded).weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Text(snap.statusLabel).font(.system(.caption2, design: .monospaced)).foregroundStyle(c)
                    .padding(.horizontal, 8).padding(.vertical, 3).overlay(Capsule().stroke(c))
            }
            Text("\(snap.profileName ?? "—") · \((snap.transport ?? "mask").uppercased()) · \(snap.endpoint ?? "—")")
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            HStack(spacing: 18) {
                Label(rate(snap.rxRate), systemImage: "arrow.down").foregroundStyle(c)
                Label(rate(snap.txRate), systemImage: "arrow.up")
            }.font(.system(.footnote, design: .monospaced))
        }
    }
}

// MARK: Quick connect (small, configurable)
struct QuickConnectWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "QuickConnectWidget", intent: QuickConnectConfig.self, provider: SnapshotProvider()) { entry in
            QuickConnectView(snap: entry.snapshot).containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Quick connect")
        .description("Connect a chosen profile.")
        .supportedFamilies([.systemSmall])
    }
}
struct QuickConnectConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Quick connect"
    @Parameter(title: "Profile") var profile: ProfileEntity?
}
struct QuickConnectView: View {
    let snap: WidgetSnapshot
    @Environment(\.widgetFamily) var family
    var body: some View {
        let c = WidgetTheme.accent("teal")
        VStack(alignment: .leading, spacing: 6) {
            GhostMark(color: c, filled: false).frame(width: 26)
            Spacer()
            Text("Connect").font(.system(.title3, design: .rounded).weight(.heavy)).foregroundStyle(.primary)
            Button(intent: ConnectVPNIntent()) { Text("Tap to connect").font(.caption2) }
                .buttonStyle(.bordered).tint(c)
        }
    }
}

// MARK: Control Center (iOS 18)
@available(iOS 18.0, *)
struct StealthControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "StealthControl") {
            ControlWidgetToggle("StealthWG", isOn: WidgetStore.load().state != .exposed, action: ToggleVPNIntent()) { on in
                Label(on ? "Masked" : "Exposed", systemImage: "shield.lefthalf.filled")
            }
        }
        .displayName("StealthWG")
    }
}
```

- [ ] **Step 6: Write `StealthWGWidgets/StealthWGWidgetBundle.swift`**

```swift
import WidgetKit
import SwiftUI

@main
struct StealthWGWidgetBundle: WidgetBundle {
    var body: some Widget {
        ShieldWidget()
        StatusBoardWidget()
        QuickConnectWidget()
        if #available(iOS 18.0, *) { StealthControl() }
    }
}
```

- [ ] **Step 7: Regenerate + build the widget extension**

Run: `xcodegen generate && xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/claude-501/-Users-user-StealthWG/build-ios CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **` (builds the app + embedded widget extension).

- [ ] **Step 8: Commit**

```bash
git add StealthWGWidgets project.yml
git commit -m "Add StealthWGWidgets: Shield, Status board, Quick connect widgets + Control Center toggle"
```

---

### Task 5: Full build + test sweep

- [ ] **Step 1:** `bash scripts/test-parser.sh` → `ALL PASSED`.
- [ ] **Step 2:** iOS app + widget build → `** BUILD SUCCEEDED **`.
- [ ] **Step 3:** macOS app build (unaffected) → `** BUILD SUCCEEDED **`.

---

## Self-Review

- **Spec coverage:** snapshot+store (T1), intents+shortcuts (T2), app publisher (T3), widget extension with 3 widgets + control (T4), builds (T5). ✓
- **Placeholder scan:** concrete code/commands throughout; the widget target's setup is fully specified. ✓
- **Type consistency:** `WidgetSnapshot`/`WidgetStore` (T1) used by intents (T2), TunnelManager (T3), widgets (T4); `ToggleVPNIntent`/`ConnectVPNIntent`/`ProfileEntity` (T2) used by widgets/control (T4); app group `group.com.stealthwg` matches `App/App.entitlements` and the widget entitlements. ✓
- **Device-only caveats noted:** Siri/Shortcuts, live widget rendering, and Control Center behavior are verified on device; builds + pure tests are the automatable gate.
