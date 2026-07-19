# Add-profile Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Apply frontend-design when writing views.

**Goal:** Replace the paste-only "Add profile" with a chooser offering Scan QR, Paste, Import file, and Create-from-scratch (a full editor with smart defaults, Advanced section, and CryptoKit key generation).

**Architecture:** `ProfileDraft` (pure, `Shared/`) holds fields, generates/derives X25519 keys via CryptoKit, and `build()`s profile text. `AddProfileView` routes the four sources; each ends at the existing `TunnelManager.importProfile`. All ingest paths unchanged downstream.

**Tech Stack:** Swift, SwiftUI, CryptoKit (X25519), UniformTypeIdentifiers (fileImporter), NetworkExtension.

## Global Constraints

- Code comments in English.
- Pure logic tested via `scripts/test-parser.sh` (swiftc compiles CryptoKit fine).
- UI verified by unsigned device build: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build` (run `xcodegen generate` first).
- CryptoKit `Curve25519.KeyAgreement` public key == `wg pubkey` (verified vector `+CzRHZBUtXJnt/TL+e2kKcfR5Vsd9qC4Ij+Eg4kaRko=` → `NF8+fWQ3lf9yrvod689ZMK2CP6H1JnYK3lER0ka4M2A=`).
- Every source ends at `TunnelManager.importProfile(_:)` (unchanged). After a successful import, the flow calls an `onComplete` closure that dismisses the whole Add sheet.
- `build()` output must parse with the existing `StealthProfile.parse` (optional lines omitted when empty; fallback endpoints → `[Stealth] Endpoints`).

## File Structure

- `Shared/ProfileDraft.swift` — fields + key gen + `build()` (Task 1).
- `App/Views/ProfileFormView.swift` — the editor (Task 2).
- `App/Views/AddProfileView.swift` — chooser + paste + fileImporter + scan (Task 3).
- `App/ContentView.swift`, `App/Views/ProfileDetailView.swift` — present `AddProfileView` (Task 4).
- Remove `App/Views/ProfileSetupView.swift` (Task 3).
- `scripts/test-parser.sh`, `Tests/StealthProfileTests.swift` — draft tests (Task 1).

---

### Task 1: `ProfileDraft` (pure model) + tests

**Files:**
- Create: `Shared/ProfileDraft.swift`
- Modify: `scripts/test-parser.sh`, `Tests/StealthProfileTests.swift`

**Interfaces:**
- Produces: `struct ProfileDraft` with `defaults()`, `derivedPublicKey`, `generateKeypair()`, `randomBase64Key()`, `build()`.

- [ ] **Step 1: Add to the test compile line**

In `scripts/test-parser.sh`, add `Shared/ProfileDraft.swift`:

```bash
swiftc -o "$BIN" \
    "$ROOT/Shared/StealthProfile.swift" \
    "$ROOT/Shared/StealthFallback.swift" \
    "$ROOT/Shared/RuntimeStats.swift" \
    "$ROOT/Shared/ProfileSummary.swift" \
    "$ROOT/Shared/ProfileDraft.swift" \
    "$ROOT/Tests/StealthProfileTests.swift"
```

- [ ] **Step 2: Write the failing tests**

Append to `Tests/StealthProfileTests.swift` inside `main()`, before the final `print`:

```swift
// ProfileDraft key derivation matches wg pubkey (known vector).
var d = ProfileDraft.defaults()
d.privateKey = "+CzRHZBUtXJnt/TL+e2kKcfR5Vsd9qC4Ij+Eg4kaRko="
check(d.derivedPublicKey == "NF8+fWQ3lf9yrvod689ZMK2CP6H1JnYK3lER0ka4M2A=", "draft derives wg public key")
check(ProfileDraft.defaults().derivedPublicKey == nil, "empty private -> nil public")
check(ProfileDraft.randomBase64Key().count == 44, "random key is 44-char base64")
var g = ProfileDraft.defaults(); g.generateKeypair()
check(g.derivedPublicKey != nil, "generated keypair has a valid public key")

// build() assembles and round-trips through StealthProfile.parse.
var b = ProfileDraft.defaults()
b.privateKey = "+CzRHZBUtXJnt/TL+e2kKcfR5Vsd9qC4Ij+Eg4kaRko="
b.serverPublicKey = "SRVPUB"
b.endpoint = "gw.example.com:51819"
b.maskKey = "MASKKEY"
b.fallbackEndpoints = ["gw.example.com:443"]
let bt = b.build()
let bp = try! StealthProfile.parse(bt)
check(bp.maskKey == "MASKKEY", "build round-trips mask key")
check(bp.endpoints == ["gw.example.com:51819", "gw.example.com:443"], "build round-trips endpoints")
check(bt.contains("PersistentKeepalive = 25"), "build includes keepalive default")
check(!bt.contains("PresharedKey"), "build omits empty preshared key")
```

- [ ] **Step 3: Run to verify it fails**

Run: `bash scripts/test-parser.sh`
Expected: FAIL — `cannot find 'ProfileDraft'`.

- [ ] **Step 4: Implement**

Create `Shared/ProfileDraft.swift`:

```swift
import Foundation
import CryptoKit

/// Editable fields for building a StealthWG profile from scratch. Pure logic;
/// generates/derives X25519 keys with CryptoKit (matches `wg`), and assembles
/// wg-quick + [Stealth] text that StealthProfile.parse accepts.
struct ProfileDraft {
    var privateKey = ""
    var address = "10.0.0.2/32"
    var dns = "1.1.1.1"
    var mtu = "1280"
    var serverPublicKey = ""
    var endpoint = ""
    var allowedIPs = "0.0.0.0/0"
    var keepalive = "25"
    var presharedKey = ""
    var fallbackEndpoints: [String] = []
    var maskKey = ""

    static func defaults() -> ProfileDraft { ProfileDraft() }

    /// Public key derived from `privateKey` (base64), or nil if it isn't valid.
    var derivedPublicKey: String? {
        let trimmed = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let data = Data(base64Encoded: trimmed), data.count == 32,
            let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        else { return nil }
        return key.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Generate a fresh X25519 client keypair; fills `privateKey`.
    mutating func generateKeypair() {
        privateKey = Curve25519.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString()
    }

    /// 32 random bytes, base64 — for the mask key or a WG preshared key.
    static func randomBase64Key() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data(Array($0)).base64EncodedString() }
    }

    /// Assemble the StealthWG profile text; optional lines are omitted when empty.
    func build() -> String {
        func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var lines = ["[Interface]", "PrivateKey = \(t(privateKey))"]
        if !t(address).isEmpty { lines.append("Address = \(t(address))") }
        if !t(dns).isEmpty { lines.append("DNS = \(t(dns))") }
        if !t(mtu).isEmpty { lines.append("MTU = \(t(mtu))") }
        lines.append("")
        lines.append("[Peer]")
        lines.append("PublicKey = \(t(serverPublicKey))")
        if !t(presharedKey).isEmpty { lines.append("PresharedKey = \(t(presharedKey))") }
        if !t(endpoint).isEmpty { lines.append("Endpoint = \(t(endpoint))") }
        if !t(allowedIPs).isEmpty { lines.append("AllowedIPs = \(t(allowedIPs))") }
        if !t(keepalive).isEmpty { lines.append("PersistentKeepalive = \(t(keepalive))") }
        lines.append("")
        lines.append("[Stealth]")
        lines.append("MaskKey = \(t(maskKey))")
        let eps = ([t(endpoint)] + fallbackEndpoints.map(t)).filter { !$0.isEmpty }
        if eps.count > 1 { lines.append("Endpoints = \(eps.joined(separator: ", "))") }
        return lines.joined(separator: "\n") + "\n"
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash scripts/test-parser.sh`
Expected: PASS — `ALL PASSED`.

- [ ] **Step 6: Commit**

```bash
git add Shared/ProfileDraft.swift scripts/test-parser.sh Tests/StealthProfileTests.swift
git commit -m "Add ProfileDraft: CryptoKit keygen + profile builder with tests"
```

---

### Task 2: `ProfileFormView` (editor)

**Files:**
- Create: `App/Views/ProfileFormView.swift`

**Interfaces:**
- Consumes: `ProfileDraft`, `TunnelManager.importProfile`.
- Produces: `ProfileFormView(onComplete: () -> Void)`.

- [ ] **Step 1: Create the view**

Create `App/Views/ProfileFormView.swift`:

```swift
import SwiftUI
import UIKit

/// Full editor: build a profile from fields, generate/derive keys, save.
struct ProfileFormView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    let onComplete: () -> Void

    @State private var draft = ProfileDraft.defaults()
    @State private var newFallback = ""

    var body: some View {
        Form {
            Section("Interface") {
                keyRow
                DraftField("Addresses", text: $draft.address)
                DraftField("DNS", text: $draft.dns)
                DisclosureGroup("Advanced") {
                    DraftField("MTU", text: $draft.mtu)
                }
            }
            Section("Peer (server)") {
                DraftField("Public key", text: $draft.serverPublicKey)
                DraftField("Endpoint", text: $draft.endpoint, placeholder: "host:port")
                DraftField("Allowed IPs", text: $draft.allowedIPs)
                DisclosureGroup("Advanced") {
                    DraftField("Persistent keepalive", text: $draft.keepalive)
                    HStack(alignment: .bottom) {
                        DraftField("Preshared key (optional)", text: $draft.presharedKey)
                        Button("Generate") { draft.presharedKey = ProfileDraft.randomBase64Key() }
                            .buttonStyle(.bordered).font(.caption)
                    }
                    ForEach(Array(draft.fallbackEndpoints.enumerated()), id: \.offset) { _, ep in
                        Text(ep).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .bottom) {
                        DraftField("Fallback endpoint", text: $newFallback, placeholder: "host:port")
                        Button("Add") {
                            let t = newFallback.trimmingCharacters(in: .whitespaces)
                            if !t.isEmpty { draft.fallbackEndpoints.append(t); newFallback = "" }
                        }.buttonStyle(.bordered).font(.caption).disabled(newFallback.isEmpty)
                    }
                }
            }
            Section("Masking") {
                HStack(alignment: .bottom) {
                    DraftField("Mask key", text: $draft.maskKey)
                    Button("Generate") { draft.maskKey = ProfileDraft.randomBase64Key() }
                        .buttonStyle(.bordered).font(.caption)
                }
            }
        }
        .navigationTitle("Create profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await tunnelManager.importProfile(draft.build())
                        if tunnelManager.hasProfile { onComplete() }
                    }
                }.disabled(!canSave)
            }
        }
    }

    private var canSave: Bool {
        [draft.privateKey, draft.serverPublicKey, draft.endpoint, draft.maskKey]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom) {
                DraftField("Private key", text: $draft.privateKey)
                Button("Generate") { draft.generateKeypair() }
                    .buttonStyle(.bordered).font(.caption)
            }
            if let pub = draft.derivedPublicKey {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Public key").font(.caption).foregroundStyle(.secondary)
                        Text(pub).font(.system(.caption2, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button { UIPasteboard.general.string = pub } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                }
                Text("Add this public key to your server as a peer.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Labeled monospace text field used across the editor.
private struct DraftField: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""
    init(_ title: String, text: Binding<String>, placeholder: String = "") {
        self.title = title; self._text = text; self.placeholder = placeholder
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder.isEmpty ? title : placeholder, text: $text)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add App/Views/ProfileFormView.swift
git commit -m "Add ProfileFormView: full profile editor with key generation"
```

---

### Task 3: `AddProfileView` (chooser) + remove `ProfileSetupView`

**Files:**
- Create: `App/Views/AddProfileView.swift`
- Delete: `App/Views/ProfileSetupView.swift`

**Interfaces:**
- Produces: `AddProfileView(onComplete: () -> Void)`; internal `PasteImportView`.

- [ ] **Step 1: Create the chooser**

Create `App/Views/AddProfileView.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers

/// Chooser for the four ways to add a profile. Every path ends at
/// TunnelManager.importProfile and then calls onComplete to dismiss.
struct AddProfileView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    let onComplete: () -> Void

    @State private var showScanner = false
    @State private var showFileImporter = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                NavigationLink { PasteImportView(onComplete: onComplete) } label: {
                    methodRow("Paste text", "A .conf with a [Stealth] section", "doc.on.clipboard")
                }
                Button { showScanner = true } label: {
                    methodRow("Scan QR code", "Import with the camera", "qrcode.viewfinder")
                }
                Button { showFileImporter = true } label: {
                    methodRow("Import file", "Choose a .conf file", "folder")
                }
                NavigationLink { ProfileFormView(onComplete: onComplete) } label: {
                    methodRow("Create from scratch", "Fill in fields, generate keys", "square.and.pencil")
                }
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("Add profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onComplete) } }
            .sheet(isPresented: $showScanner) {
                QRScannerView(
                    onScan: { code in
                        showScanner = false
                        Task { await tunnelManager.importProfile(code); if tunnelManager.hasProfile { onComplete() } }
                    },
                    onError: { m in errorText = m; showScanner = false }
                ).ignoresSafeArea()
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { importFromFile(url) }
            }
        }
    }

    private func importFromFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            errorText = "Could not read the file."
            return
        }
        Task { await tunnelManager.importProfile(text); if tunnelManager.hasProfile { onComplete() } }
    }

    private func methodRow(_ title: String, _ subtitle: String, _ system: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: system).font(.title3).foregroundStyle(Theme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.body, design: .rounded).weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

/// Paste-a-profile sub-screen.
struct PasteImportView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    let onComplete: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a StealthWG profile (a .conf with a [Stealth] section).")
                .font(.footnote).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.3)))
            if let e = tunnelManager.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
            Spacer()
        }
        .padding()
        .navigationTitle("Paste")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") {
                    Task { await tunnelManager.importProfile(text); if tunnelManager.hasProfile { onComplete() } }
                }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
```

- [ ] **Step 2: Delete the old setup view**

Run: `git rm App/Views/ProfileSetupView.swift`

- [ ] **Step 3: Commit**

```bash
git add App/Views/AddProfileView.swift
git commit -m "Add AddProfileView chooser (QR/paste/file/scratch); remove ProfileSetupView"
```

---

### Task 4: Wire `ContentView` + `ProfileDetailView` + build

**Files:**
- Modify: `App/ContentView.swift`, `App/Views/ProfileDetailView.swift`

**Interfaces:**
- Consumes: `AddProfileView(onComplete:)`.

- [ ] **Step 1: ContentView presents AddProfileView**

In `App/ContentView.swift`, replace the sheet presentation. Change the sheet so the empty-state add and the connection-screen profile chip use the right sheets:

```swift
        .sheet(isPresented: $showProfileSheet) {
            if tunnelManager.hasProfile {
                ProfileDetailView().environmentObject(tunnelManager)
            } else {
                AddProfileView(onComplete: { showProfileSheet = false }).environmentObject(tunnelManager)
            }
        }
```

- [ ] **Step 2: ProfileDetailView "Replace" presents AddProfileView**

In `App/Views/ProfileDetailView.swift`, replace the `showReplace` sheet body:

```swift
            .sheet(isPresented: $showReplace) {
                AddProfileView(onComplete: { showReplace = false }).environmentObject(tunnelManager)
            }
```

- [ ] **Step 3: Regenerate + unsigned device build**

Run: `xcodegen generate && export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" && xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Re-run pure tests**

Run: `bash scripts/test-parser.sh`
Expected: `ALL PASSED`.

- [ ] **Step 5: Commit**

```bash
git add App/ContentView.swift App/Views/ProfileDetailView.swift
git commit -m "Wire AddProfileView into empty state and profile replace"
```

---

## Self-Review

**Spec coverage:**
- Four sources (Scan/Paste/File/Scratch) → Task 3 (`AddProfileView`) + Task 2 (form). ✓
- Full editor with smart defaults + Advanced + key generation + derived public key copy → Task 2 + Task 1 (`ProfileDraft`). ✓
- CryptoKit keygen == wg pubkey, tested → Task 1. ✓
- `build()` round-trips through parse, optional lines omitted → Task 1. ✓
- All paths end at `importProfile`; `onComplete` dismisses → Tasks 2/3/4. ✓
- Device build + tests → Task 4. ✓

**Placeholder scan:** No TODOs; every step has complete code.

**Type/name consistency:** `ProfileDraft` members (`derivedPublicKey`, `generateKeypair`, `randomBase64Key`, `build`) used in Tasks 1/2 match. `AddProfileView(onComplete:)`, `ProfileFormView(onComplete:)`, `PasteImportView(onComplete:)` signatures match their call sites (Tasks 3/4). `TunnelManager.importProfile`/`hasProfile`/`lastError` exist. `Theme.accent` exists. Removed `ProfileSetupView` is no longer referenced after Task 4 (ContentView + ProfileDetailView updated).
