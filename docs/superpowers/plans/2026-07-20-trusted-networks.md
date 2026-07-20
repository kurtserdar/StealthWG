# Trusted Networks (Network-Based Auto-Connect) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a per-profile on-demand VPN skip auto-connecting on trusted Wi-Fi SSIDs (typed by the user) while still auto-connecting everywhere else, with an optional "auto-connect on cellular" control.

**Architecture:** A pure `onDemandRuleSpecs` builder (`Shared/`) produces an ordered rule model; `TunnelManager` adapts it to `NEOnDemandRule` when on-demand is enabled and persists trusted networks in `providerConfiguration`; a shared `TrustedNetworksView` edits the list.

**Tech Stack:** Swift, SwiftUI, NetworkExtension (`NEOnDemandRuleConnect/Ignore`, `ssidMatch`, `interfaceTypeMatch`), `scripts/test-parser.sh`.

## Global Constraints

- **No location permission:** SSIDs are matched by the system via `ssidMatch`; the app never reads the current SSID. (Approach B "add current network" is a deferred follow-up.)
- **Ignore, not Disconnect,** on trusted networks (don't auto-connect; respect a manual connect).
- Single-always-on enforcement and kill-switch behavior are unchanged.
- **Cross-platform:** pure model in `Shared/`; `TrustedNetworksView` in `App/Views/` (compiled by both app targets, not the extension).
- **English code comments.** Pure logic covered by `scripts/test-parser.sh`; iOS + macOS device builds stay green.

## File Structure

- `Shared/OnDemandRules.swift` — pure rule-spec builder (unit-tested).
- `App/TunnelManager.swift` — profile fields, rule adapter, `setTrustedNetworks`, save-preserve, reload-derive.
- `App/Views/TrustedNetworksView.swift` — editable SSID list + cellular toggle.
- `App/Views/ProfileDetailView.swift` — entry point (shown when on-demand is on).
- `Tests/StealthProfileTests.swift` + `scripts/test-parser.sh` — unit tests.

---

### Task 1: `OnDemandRules` builder (pure, tested)

**Files:**
- Create: `Shared/OnDemandRules.swift`
- Modify: `Tests/StealthProfileTests.swift`, `scripts/test-parser.sh`

**Interfaces:**
- Produces: `OnDemandAction`, `OnDemandInterface`, `OnDemandRuleSpec`, `onDemandRuleSpecs(trustedSSIDs:trustCellular:)` — consumed by `TunnelManager` (Task 2).

- [ ] **Step 1: Write `Shared/OnDemandRules.swift`**

```swift
import Foundation

enum OnDemandAction: Equatable { case connect, ignore, disconnect }
enum OnDemandInterface: Equatable { case any, wifi, cellular }

/// A transport-agnostic description of one on-demand rule (adapted to
/// NEOnDemandRule in TunnelManager). Pure so the ordering logic is testable.
struct OnDemandRuleSpec: Equatable {
    let action: OnDemandAction
    let interface: OnDemandInterface
    let ssids: [String]   // empty = no SSID constraint
}

/// Builds the ordered rule specs: Ignore on trusted Wi-Fi SSIDs, optionally Ignore
/// on cellular, then Connect everywhere. Blank SSIDs are dropped; SSIDs de-duped.
func onDemandRuleSpecs(trustedSSIDs: [String], trustCellular: Bool) -> [OnDemandRuleSpec] {
    var seen = Set<String>()
    let clean = trustedSSIDs
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && seen.insert($0).inserted }

    var specs: [OnDemandRuleSpec] = []
    if !clean.isEmpty {
        specs.append(OnDemandRuleSpec(action: .ignore, interface: .wifi, ssids: clean))
    }
    if trustCellular {
        specs.append(OnDemandRuleSpec(action: .ignore, interface: .cellular, ssids: []))
    }
    specs.append(OnDemandRuleSpec(action: .connect, interface: .any, ssids: []))
    return specs
}
```

- [ ] **Step 2: Write failing tests** — append inside `main()` in `Tests/StealthProfileTests.swift` before the final `print`:

```swift
        // On-demand rule specs: trusted Wi-Fi Ignore + optional cellular + Connect.
        check(onDemandRuleSpecs(trustedSSIDs: [], trustCellular: false)
              == [OnDemandRuleSpec(action: .connect, interface: .any, ssids: [])],
              "empty -> connect everywhere")
        check(onDemandRuleSpecs(trustedSSIDs: ["Home"], trustCellular: false)
              == [OnDemandRuleSpec(action: .ignore, interface: .wifi, ssids: ["Home"]),
                  OnDemandRuleSpec(action: .connect, interface: .any, ssids: [])],
              "ssids -> ignore wifi then connect")
        check(onDemandRuleSpecs(trustedSSIDs: ["Home", "Work"], trustCellular: true)
              == [OnDemandRuleSpec(action: .ignore, interface: .wifi, ssids: ["Home", "Work"]),
                  OnDemandRuleSpec(action: .ignore, interface: .cellular, ssids: []),
                  OnDemandRuleSpec(action: .connect, interface: .any, ssids: [])],
              "ssids + cellular -> three rules in order")
        check(onDemandRuleSpecs(trustedSSIDs: [], trustCellular: true)
              == [OnDemandRuleSpec(action: .ignore, interface: .cellular, ssids: []),
                  OnDemandRuleSpec(action: .connect, interface: .any, ssids: [])],
              "cellular only -> ignore cellular then connect")
        check(onDemandRuleSpecs(trustedSSIDs: [" Home ", "", "Home"], trustCellular: false)[0].ssids == ["Home"],
              "blank dropped and ssids de-duplicated/trimmed")
```

- [ ] **Step 3: Add the source to `scripts/test-parser.sh`** — after `ConnectionDiagnostics.swift`:

```sh
    "$ROOT/Shared/ConnectionDiagnostics.swift" \
    "$ROOT/Shared/OnDemandRules.swift" \
    "$ROOT/Tests/StealthProfileTests.swift"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash scripts/test-parser.sh`
Expected: `ALL PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Shared/OnDemandRules.swift Tests/StealthProfileTests.swift scripts/test-parser.sh
git commit -m "Add OnDemandRules: pure trusted-network rule-spec builder"
```

---

### Task 2: TunnelManager — trusted networks wiring

**Files:**
- Modify: `App/TunnelManager.swift`

**Interfaces:**
- Consumes: `OnDemandRuleSpec`, `onDemandRuleSpecs` (Task 1).
- Produces: `TunnelProfile.trustedSSIDs`/`trustCellular`; `setTrustedNetworks(id:ssids:trustCellular:)` — consumed by `TrustedNetworksView` (Task 3).

- [ ] **Step 1: Add the fields to `TunnelProfile`** (after `allowLocal`):

```swift
    var trustedSSIDs: [String] = []   // Wi-Fi SSIDs where on-demand should not auto-connect
    var trustCellular: Bool = false   // when true, don't auto-connect on cellular
```

- [ ] **Step 2: Derive them at reload.** In the `TunnelProfile(...)` construction (around line 86), read from `providerConfiguration`:

```swift
            list.append(TunnelProfile(
                id: id, name: m.localizedDescription ?? "StealthWG", profile: parsed,
                onDemand: m.isOnDemandEnabled,
                killSwitch: proto.includeAllNetworks,
                allowLocal: proto.excludeLocalNetworks,
                trustedSSIDs: proto.providerConfiguration?["trustedSSIDs"] as? [String] ?? [],
                trustCellular: proto.providerConfiguration?["trustCellular"] as? Bool ?? false
            ))
```

- [ ] **Step 3: Add the rule adapter** (private, near `setOnDemand`):

```swift
    private func makeOnDemandRules(_ specs: [OnDemandRuleSpec]) -> [NEOnDemandRule] {
        specs.map { spec in
            let rule: NEOnDemandRule
            switch spec.action {
            case .connect: rule = NEOnDemandRuleConnect()
            case .ignore: rule = NEOnDemandRuleIgnore()
            case .disconnect: rule = NEOnDemandRuleDisconnect()
            }
            switch spec.interface {
            case .any: rule.interfaceTypeMatch = .any
            case .wifi: rule.interfaceTypeMatch = .wiFi
            case .cellular: rule.interfaceTypeMatch = .cellular
            }
            if !spec.ssids.isEmpty { rule.ssidMatch = spec.ssids }
            return rule
        }
    }

    /// Reads a manager's persisted trusted networks from providerConfiguration.
    private func trustedNetworks(of m: NETunnelProviderManager) -> (ssids: [String], cellular: Bool) {
        let pc = (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        return (pc?["trustedSSIDs"] as? [String] ?? [], pc?["trustCellular"] as? Bool ?? false)
    }
```

- [ ] **Step 4: Build rules from trusted networks in `setOnDemand`.** Replace the fixed rule:

```swift
                let (ssids, cellular) = trustedNetworks(of: m)
                m.onDemandRules = makeOnDemandRules(onDemandRuleSpecs(trustedSSIDs: ssids, trustCellular: cellular))
                m.isOnDemandEnabled = true
```
(remove the old `let rule = NEOnDemandRuleConnect(); rule.interfaceTypeMatch = .any; m.onDemandRules = [rule]`.)

- [ ] **Step 5: Add `setTrustedNetworks`** (after `setOnDemand`):

```swift
    func setTrustedNetworks(id: String, ssids: [String], trustCellular: Bool) async {
        guard let m = managers[id], let proto = m.protocolConfiguration as? NETunnelProviderProtocol else { return }
        var pc = proto.providerConfiguration ?? [:]
        pc["trustedSSIDs"] = ssids
        pc["trustCellular"] = trustCellular
        proto.providerConfiguration = pc
        m.protocolConfiguration = proto
        if m.isOnDemandEnabled {
            m.onDemandRules = makeOnDemandRules(onDemandRuleSpecs(trustedSSIDs: ssids, trustCellular: trustCellular))
        }
        m.isEnabled = true
        do {
            try await m.saveToPreferences()
            await reloadAndSelect(preferID: id)
        } catch {
            lastError = error.localizedDescription
        }
    }
```

- [ ] **Step 6: Preserve trusted networks across a profile edit** in `save(profile:name:into:id:)`, next to the transport/sni writes (using the existing `existing` protocol):

```swift
        if let ex = existing?.providerConfiguration {
            if let ssids = ex["trustedSSIDs"] as? [String] { pc["trustedSSIDs"] = ssids }
            if let cell = ex["trustCellular"] as? Bool { pc["trustCellular"] = cell }
        }
```

- [ ] **Step 7: Build the iOS app**

Run: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/claude-501/-Users-user-StealthWG/build-ios CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add App/TunnelManager.swift
git commit -m "TunnelManager: build on-demand rules from trusted networks; persist trustedSSIDs/trustCellular"
```

---

### Task 3: `TrustedNetworksView` + entry point

**Files:**
- Create: `App/Views/TrustedNetworksView.swift`
- Modify: `App/Views/ProfileDetailView.swift`

**Interfaces:**
- Consumes: `TunnelManager.setTrustedNetworks`, `TunnelProfile.trustedSSIDs/trustCellular`; `inlineNavTitle`, `noAutocap`.

- [ ] **Step 1: Write `App/Views/TrustedNetworksView.swift`**

```swift
import SwiftUI

/// Edits the Wi-Fi SSIDs where on-demand should not auto-connect, plus the
/// cellular preference. Applies each change immediately via the tunnel manager.
struct TrustedNetworksView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    let profileID: String

    @State private var ssids: [String]
    @State private var trustCellular: Bool
    @State private var newSSID = ""

    init(profileID: String, ssids: [String], trustCellular: Bool) {
        self.profileID = profileID
        _ssids = State(initialValue: ssids)
        _trustCellular = State(initialValue: trustCellular)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Auto-connect on cellular data", isOn: Binding(
                    get: { !trustCellular },
                    set: { trustCellular = !$0; apply() }))
            } footer: {
                Text("On the Wi-Fi networks below StealthWG won't connect automatically; everywhere else it will. You can still connect manually.")
            }

            Section("Trusted Wi-Fi networks") {
                ForEach(ssids, id: \.self) { ssid in
                    Text(ssid).font(.system(.footnote, design: .monospaced))
                }
                .onDelete { idx in
                    ssids.remove(atOffsets: idx); apply()
                }
                HStack {
                    TextField("Wi-Fi network name (SSID)", text: $newSSID)
                        .noAutocap()
                    Button("Add") {
                        let t = newSSID.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty, !ssids.contains(t) { ssids.append(t) }
                        newSSID = ""
                        apply()
                    }.disabled(newSSID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle("Trusted networks")
        .inlineNavTitle()
    }

    private func apply() {
        Task { await tunnelManager.setTrustedNetworks(id: profileID, ssids: ssids, trustCellular: trustCellular) }
    }
}
```

- [ ] **Step 2: Add the entry point** in `App/Views/ProfileDetailView.swift`, inside "VPN options", after the "Connect on demand" toggle + its caption. Show it only when on-demand is on:

```swift
                    if current.onDemand {
                        NavigationLink {
                            TrustedNetworksView(
                                profileID: profile.id,
                                ssids: current.trustedSSIDs,
                                trustCellular: current.trustCellular)
                        } label: {
                            Label("Trusted networks", systemImage: "wifi.circle")
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
git add App/Views/TrustedNetworksView.swift App/Views/ProfileDetailView.swift
git commit -m "Add TrustedNetworksView + entry point under Connect on demand"
```

---

### Task 4: Full build + test sweep

**Files:** none (verification only).

- [ ] **Step 1:** `bash scripts/test-parser.sh` → `ALL PASSED`.
- [ ] **Step 2:** iOS device build → `** BUILD SUCCEEDED **`.
- [ ] **Step 3:** macOS device build → `** BUILD SUCCEEDED **`.

---

## Self-Review

- **Spec coverage:** pure builder (T1), TunnelManager wiring + persistence + adapter (T2), view + entry point (T3), builds (T4). Ignore-on-trusted + optional cellular + connect-everywhere all in T1/T2. ✓
- **Placeholder scan:** every step has concrete code/commands; no TBD/TODO. ✓
- **Type consistency:** `OnDemandRuleSpec{action,interface,ssids}` and `onDemandRuleSpecs(trustedSSIDs:trustCellular:)` from T1 are used verbatim in T2; `setTrustedNetworks(id:ssids:trustCellular:)` matches the T3 call; `TunnelProfile.trustedSSIDs/trustCellular` set in T2 are read in T3. `NEOnDemandRuleInterfaceType.wiFi` (capital F) used in the adapter. ✓
- **Cross-platform:** pure model in `Shared/`; `TrustedNetworksView` in `App/Views/` (both app targets); entry point in shared `ProfileDetailView`; extension unaffected. ✓
