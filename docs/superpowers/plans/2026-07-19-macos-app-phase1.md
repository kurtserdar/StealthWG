# macOS App Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A compiling native macOS StealthWG: menu-bar app + packet-tunnel System Extension, reusing shared logic + adapted SwiftUI, with the wireguard-go bridge built for darwin.

**Architecture:** Centralise platform differences in `App/Platform.swift`; guard the few iOS-only spots in shared views; add a `macOS/` shell (MenuBarExtra + management window + SystemExtensionManager); add two macOS targets to `project.yml`. Verify with an unsigned macOS build while keeping the iOS build green.

**Tech Stack:** SwiftUI (`MenuBarExtra`, macOS 13+), NetworkExtension, SystemExtensions, WireGuardKit, XcodeGen.

## Global Constraints

- Code comments in English.
- Keep the iOS build green: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build`.
- macOS verification: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG-mac -sdk macosx -configuration Debug CODE_SIGNING_ALLOWED=NO build`.
- `scripts/test-parser.sh` stays green (pure logic untouched).
- Bundle ids: mac app `com.stealthwg`, mac sysext `com.stealthwg.tunnel`. App Group `group.com.stealthwg`.
- The mac app target excludes iOS-only files: `App/StealthWGApp.swift`, `App/ContentView.swift`, `App/LaunchScreen.storyboard`, `App/Assets.xcassets`, `App/QRScannerView.swift`.
- Regenerate with `xcodegen generate` after any `project.yml` change.

## File Structure

- `App/Platform.swift` — `PlatformImage` typealias, `Clipboard.copy`, `inlineNavTitle()` (Task 1).
- Adapted views: `App/QRCodeView.swift`, `App/Views/ProfileFormView.swift`, `App/Views/AddProfileView.swift`, `App/Views/ProfileDetailView.swift` (Task 1).
- `macOS/StealthWGMacApp.swift`, `MacMenuView.swift`, `SystemExtensionManager.swift`, `StealthWG-mac.entitlements`, `Assets.xcassets/AppIcon.appiconset` (Task 2).
- `Tunnel/PacketTunnel-mac.entitlements` (Task 3).
- `project.yml` — macOS deployment + `StealthWG-mac` + `PacketTunnel-mac` (Task 3).

---

### Task 1: Cross-platform view adaptation

**Files:**
- Create: `App/Platform.swift`
- Modify: `App/QRCodeView.swift`, `App/Views/ProfileFormView.swift`, `App/Views/AddProfileView.swift`, `App/Views/ProfileDetailView.swift`

**Interfaces:**
- Produces: `PlatformImage`, `Clipboard.copy(_:)`, `View.inlineNavTitle()`.

- [ ] **Step 1: Create `App/Platform.swift`**

```swift
import SwiftUI
#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage
#endif

/// Cross-platform clipboard write.
enum Clipboard {
    static func copy(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

extension View {
    /// Inline nav-title on iOS; no-op on macOS (which has no title display mode).
    @ViewBuilder func inlineNavTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Disable autocapitalization on iOS; no-op on macOS.
    @ViewBuilder func noAutocap() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}
```

- [ ] **Step 2: Adapt `QRCodeView` to `PlatformImage`**

Replace the `import UIKit` + `qrImage` return/usage: `static func qrImage(from:) -> PlatformImage?` building `NSImage(cgImage:size:)` on macOS, `UIImage(cgImage:)` on iOS; display with a platform initializer:

```swift
import SwiftUI
import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    let text: String
    var body: some View {
        VStack(spacing: 16) {
            if let image = Self.qrImage(from: text) {
                #if os(iOS)
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 280).accessibilityLabel("Profile QR code")
                #elseif os(macOS)
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 280).accessibilityLabel("Profile QR code")
                #endif
            } else {
                Text("Could not render QR code.").foregroundStyle(.red)
            }
            Text("Scan this on another device to import the profile.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding()
    }

    static func qrImage(from text: String) -> PlatformImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cg)
        #elseif os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }
}
```

- [ ] **Step 3: Adapt `ProfileFormView`**

Remove `import UIKit`. Replace `UIPasteboard.general.string = pub` with `Clipboard.copy(pub)`. Replace `.navigationBarTitleDisplayMode(.inline)` with `.inlineNavTitle()`. In `DraftField`, replace `.textInputAutocapitalization(.never)` with `.noAutocap()`.

- [ ] **Step 4: Adapt `AddProfileView`**

Guard the Scan-QR row + scanner sheet with `#if os(iOS)`:

```swift
                #if os(iOS)
                Button { showScanner = true } label: {
                    methodRow("Scan QR code", "Import with the camera", "qrcode.viewfinder")
                }
                #endif
```
and wrap the `.sheet(isPresented: $showScanner) { QRScannerView(...) }` and `@State private var showScanner` in `#if os(iOS)`. Replace `.navigationBarTitleDisplayMode(.inline)` with `.inlineNavTitle()` (both here and in `PasteImportView`).

- [ ] **Step 5: Adapt `ProfileDetailView`**

Replace `.navigationBarTitleDisplayMode(.inline)` with `.inlineNavTitle()`.

- [ ] **Step 6: iOS build still green**

Run: `xcodegen generate && export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" && xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. (project.yml unchanged yet, but regenerate is harmless.)

- [ ] **Step 7: Commit**

```bash
git add App/Platform.swift App/QRCodeView.swift App/Views/ProfileFormView.swift App/Views/AddProfileView.swift App/Views/ProfileDetailView.swift
git commit -m "Make shared views cross-platform (Platform.swift + guards)"
```

---

### Task 2: macOS shell

**Files:**
- Create: `macOS/StealthWGMacApp.swift`, `macOS/MacMenuView.swift`, `macOS/SystemExtensionManager.swift`, `macOS/StealthWG-mac.entitlements`, `macOS/Assets.xcassets/{Contents.json,AppIcon.appiconset/*}`

**Interfaces:**
- Produces: the `@main` mac app, menu content, extension activation manager.

- [ ] **Step 1: `SystemExtensionManager.swift`**

```swift
import Foundation
import SystemExtensions

/// Requests activation of the packet-tunnel System Extension. Actual activation
/// requires a signed, notarized app the user approves in System Settings.
final class SystemExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var statusMessage = ""
    static let extensionIdentifier = "com.stealthwg.tunnel"

    func activate() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        statusMessage = "Requesting activation…"
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        statusMessage = "Approve StealthWG in System Settings → Privacy & Security."
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        statusMessage = "Extension ready."
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        statusMessage = "Activation failed: \(error.localizedDescription)"
    }
}
```

- [ ] **Step 2: `MacMenuView.swift`**

```swift
import SwiftUI
import NetworkExtension

/// Compact menu-bar panel: status, connect toggle, live endpoint/throughput.
struct MacMenuView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @Environment(\.openWindow) private var openWindow

    private var isActive: Bool {
        switch tunnelManager.status {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(Theme.color(for: tunnelManager.status)).frame(width: 10, height: 10)
                Text(Theme.label(for: tunnelManager.status))
                    .font(.system(.headline, design: .rounded))
                Spacer()
            }
            if let s = tunnelManager.stats, tunnelManager.status == .connected {
                Text("↓ \(StatsView.rate(s.rxRate))   ↑ \(StatsView.rate(s.txRate))")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                if let ep = s.activeEndpoint {
                    Text(ep).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Button(isActive ? "Disconnect" : "Connect") {
                isActive ? tunnelManager.disconnect() : tunnelManager.connect()
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .disabled(!tunnelManager.hasProfile)
            Divider()
            Button("Manage profile…") { openWindow(id: "manage") }
            Button("Quit StealthWG") { NSApplication.shared.terminate(nil) }
        }
        .padding(14).frame(width: 260)
    }
}
```

- [ ] **Step 3: `StealthWGMacApp.swift`**

```swift
import SwiftUI

@main
struct StealthWGMacApp: App {
    @StateObject private var tunnelManager = TunnelManager()

    var body: some Scene {
        MenuBarExtra("StealthWG", systemImage: "shield.lefthalf.filled") {
            MacMenuView()
                .environmentObject(tunnelManager)
                .task { await tunnelManager.load() }
        }
        .menuBarExtraStyle(.window)

        Window("StealthWG", id: "manage") {
            ManageWindow()
                .environmentObject(tunnelManager)
                .frame(minWidth: 420, minHeight: 480)
                .preferredColorScheme(.dark)
        }
    }
}

/// Management window: empty state or profile detail, both reusing shared views.
private struct ManageWindow: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @State private var showAdd = false
    var body: some View {
        Group {
            if tunnelManager.hasProfile {
                ProfileDetailView().environmentObject(tunnelManager)
            } else {
                VStack(spacing: 16) {
                    Image("MacGhost").resizable().scaledToFit().frame(width: 72, height: 72)
                    Text("Add a profile to get started.").foregroundStyle(.secondary)
                    Button("Add profile") { showAdd = true }.buttonStyle(.borderedProminent).tint(Theme.accent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showAdd) {
            AddProfileView(onComplete: { showAdd = false }).environmentObject(tunnelManager)
        }
    }
}
```

Note: `Image("MacGhost")` — add a `MacGhost` imageset in `macOS/Assets.xcassets` (from `branding/mark-silver.svg`, transparent). If time-boxed, use `Image(systemName: "shield.lefthalf.filled")` instead to avoid the asset dependency; the plan's Step 5 adds the asset.

- [ ] **Step 4: `macOS/StealthWG-mac.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.networking.networkextension</key>
    <array><string>packet-tunnel-provider-systemextension</string></array>
    <key>com.apple.security.application-groups</key>
    <array><string>group.com.stealthwg</string></array>
    <key>com.apple.developer.system-extension.install</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 5: macOS app icon + ghost asset**

Render from the kit and build the asset catalog:

```bash
export PATH="/opt/homebrew/bin:$PATH"
mkdir -p macOS/Assets.xcassets/AppIcon.appiconset macOS/Assets.xcassets/MacGhost.imageset
# opaque 1024 app icon (macOS masks less; provide full-bleed 1024)
rsvg-convert -w 1024 -h 1024 branding/icon-macos.svg -o /tmp/mac-icon.png
sips -s format jpeg -s formatOptions 100 /tmp/mac-icon.png --out /tmp/mi.jpg >/dev/null
sips -s format png /tmp/mi.jpg --out macOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png >/dev/null
rsvg-convert -w 512 -h 512 branding/mark-silver.svg -o macOS/Assets.xcassets/MacGhost.imageset/ghost.png
```

Write `macOS/Assets.xcassets/Contents.json`, `AppIcon.appiconset/Contents.json` (single `mac` 1024 icon: `{"idiom":"mac","size":"512x512","scale":"2x","filename":"icon-1024.png"}` inside the images array), and `MacGhost.imageset/Contents.json` (single universal image). (macOS icon sets historically want multiple sizes; a single 512@2x entry is accepted by actool for a dev build.)

- [ ] **Step 6: Commit (build happens in Task 4)**

```bash
git add macOS
git commit -m "Add macOS shell: menu-bar app, manage window, system-extension manager"
```

---

### Task 3: `project.yml` macOS targets

**Files:**
- Modify: `project.yml`
- Create: `Tunnel/PacketTunnel-mac.entitlements`

- [ ] **Step 1: Tunnel mac entitlements**

`Tunnel/PacketTunnel-mac.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.networking.networkextension</key>
    <array><string>packet-tunnel-provider-systemextension</string></array>
    <key>com.apple.security.application-groups</key>
    <array><string>group.com.stealthwg</string></array>
</dict>
</plist>
```

- [ ] **Step 2: Add macOS deployment + targets to `project.yml`**

Under `options.deploymentTarget`, add `macOS: "13.0"`. Append two targets:

```yaml
  # ── macOS menu-bar application ─────────────────────────────────────────────
  StealthWG-mac:
    type: application
    platform: macOS
    sources:
      - Shared
      - macOS
      - path: App/Views
      - path: App/TunnelManager.swift
      - path: App/Theme.swift
      - path: App/QRCodeView.swift
      - path: App/Platform.swift
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.stealthwg
        PRODUCT_NAME: StealthWG
        CODE_SIGN_ENTITLEMENTS: macOS/StealthWG-mac.entitlements
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_CFBundleDisplayName: StealthWG
        INFOPLIST_KEY_LSUIElement: YES   # menu-bar only, no Dock icon
        MARKETING_VERSION: "0.1.0"
    dependencies:
      - target: PacketTunnel-mac
        embed: true
      - package: WireGuardKit
        product: WireGuardKit

  # ── macOS packet tunnel System Extension ───────────────────────────────────
  PacketTunnel-mac:
    type: system-extension
    platform: macOS
    sources:
      - Tunnel
      - Shared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.stealthwg.tunnel
        PRODUCT_NAME: com.stealthwg.tunnel
        CODE_SIGN_ENTITLEMENTS: Tunnel/PacketTunnel-mac.entitlements
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_FILE: Tunnel/Info.plist
        SWIFT_OBJC_BRIDGING_HEADER: Tunnel/StealthBridge.h
    dependencies:
      - package: WireGuardKit
        product: WireGuardKit
    preBuildScripts:
      - name: Build wireguard-go bridge
        basedOnDependencyAnalysis: false
        script: |
          set -e
          export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
          make -C "$SRCROOT/ThirdParty/wireguard-apple/Sources/WireGuardKitGo"
```

If `xcodegen generate` rejects `type: system-extension`, replace it with
`type: ""` + `PRODUCT_TYPE: com.apple.product-type.system-extension` under
`settings.base`, and add `productType` handling as needed.

Note: the mac System Extension's `Info.plist` needs an `NEProviderClasses` /
`NetworkExtension` `NSExtensionPointIdentifier` of `com.apple.networkextension.packet-tunnel`.
`Tunnel/Info.plist` (shared with iOS) already declares the packet-tunnel
NSExtension keys; reuse it. If the system-extension requires
`CFBundlePackageType=SYSX`, add it via an `INFOPLIST_KEY`/plist entry during the
build fix-up.

- [ ] **Step 3: Commit**

```bash
git add project.yml Tunnel/PacketTunnel-mac.entitlements
git commit -m "project.yml: add macOS app + packet-tunnel system-extension targets"
```

---

### Task 4: Generate + build both platforms

- [ ] **Step 1: Regenerate**

Run: `xcodegen generate`
Expected: project created with `StealthWG-mac` and `PacketTunnel-mac` schemes.

- [ ] **Step 2: macOS unsigned build**

Run: `export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" && xcodebuild -project StealthWG.xcodeproj -scheme StealthWG-mac -sdk macosx -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -8`
Expected: `** BUILD SUCCEEDED **`. Resolve compile errors (missing platform guards, sysext plist/type) as they surface; re-run.

- [ ] **Step 3: iOS build still green**

Run: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Pure tests still green**

Run: `bash scripts/test-parser.sh`
Expected: `ALL PASSED`.

- [ ] **Step 5: Commit any build fix-ups**

```bash
git add -A
git commit -m "macOS Phase 1: green unsigned build (mac app + system extension)"
```

---

## Self-Review

**Spec coverage:**
- macOS menu-bar app + management window → Task 2/3. ✓
- Packet-tunnel System Extension target + darwin Go bridge → Task 3. ✓
- Shared logic + adapted views (Platform.swift, guards, drop mac camera) → Task 1. ✓
- SystemExtensionManager (activation request) → Task 2. ✓
- Entitlements (networkextension systemextension + app groups) → Task 2/3. ✓
- macOS icon from the kit → Task 2. ✓
- Compile verification (mac + iOS) + tests → Task 4. ✓

**Placeholder scan:** The only conditional is the documented XcodeGen `system-extension` fallback (explicit PRODUCT_TYPE) and sysext plist fix-ups — both are real, described actions to take if the build demands them, not vague TODOs.

**Type/name consistency:** `PlatformImage`/`Clipboard.copy`/`inlineNavTitle`/`noAutocap` (Task 1) are used by `QRCodeView`/`ProfileFormView`/`AddProfileView`/`ProfileDetailView`. `MacMenuView` and `ManageWindow` consume `TunnelManager` members (`status`/`stats`/`hasProfile`/`connect`/`disconnect`/`load`) and shared views (`ProfileDetailView`, `AddProfileView`) that exist. `StatsView.rate` is `static` (usable from `MacMenuView`). `SystemExtensionManager.extensionIdentifier` matches the sysext bundle id `com.stealthwg.tunnel`.
