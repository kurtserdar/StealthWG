# iOS QR Import + Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add QR-code import (scan the bundle's QR) and export (show the current profile as a QR) to the iOS app.

**Architecture:** A new `serialize()` on `StealthProfile` reconstructs raw profile text from the split fields (inverse of `parse`, round-trip tested). `TunnelManager.currentProfileText()` rebuilds the raw text from `providerConfiguration` for export. `QRCodeView` renders a QR via CoreImage; `QRScannerView` scans via AVFoundation. `ContentView` gets Scan QR / Show QR buttons + sheets. Camera permission via a `project.yml` Info.plist key.

**Tech Stack:** Swift, SwiftUI, AVFoundation (scan), CoreImage (`CIFilter.qrCodeGenerator`, render), NetworkExtension, XcodeGen.

## Global Constraints

- Code comments in English.
- Pure-logic tests run via `scripts/test-parser.sh` (swiftc compiles `Shared/StealthProfile.swift` + `Tests/StealthProfileTests.swift`); the packet extension is device-only, so no XCTest bundle.
- UI/camera code is verified by an unsigned device build: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build`. Regenerate the project first with `xcodegen generate`.
- New UIKit/AVFoundation views live in `App/` (app target only), not `Shared/`.
- The QR payload is the raw StealthWG profile text (wg-quick + `[Stealth]` section); no standard-WG-compatible variant.
- `StealthProfile` keeps its synthesized memberwise init (`StealthProfile(wgQuickConfig:maskKey:)`); do not add a custom init that would suppress it.

## File Structure

- `Shared/StealthProfile.swift` — add `serialize()` (Task 1).
- `Tests/StealthProfileTests.swift` — add serialize + round-trip checks (Task 1).
- `App/TunnelManager.swift` — add `currentProfileText()` (Task 2).
- `App/QRCodeView.swift` — QR image + view (Task 3).
- `App/QRScannerView.swift` — camera scanner (Task 4).
- `App/ContentView.swift` — buttons + sheets (Task 5).
- `project.yml` — camera usage description (Task 5).

---

### Task 1: `StealthProfile.serialize()` + round-trip tests

**Files:**
- Modify: `Shared/StealthProfile.swift`
- Modify: `Tests/StealthProfileTests.swift`

**Interfaces:**
- Consumes: existing `StealthProfile` (`wgQuickConfig`, `maskKey`, `parse`).
- Produces: `func serialize() -> String` — inverse of `parse`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/StealthProfileTests.swift` inside `main()`, before the final `print`:

```swift
// serialize(): reconstructs raw text with a [Stealth] section when masked.
let s = StealthProfile(wgQuickConfig: "[Interface]\nPrivateKey = aaaa", maskKey: "kkkk").serialize()
check(s.contains("[Interface]"), "serialize keeps wg config")
check(s.contains("[Stealth]"), "serialize adds [Stealth] when masked")
check(s.contains("MaskKey = kkkk"), "serialize writes MaskKey")

let plainS = StealthProfile(wgQuickConfig: "[Interface]\nPrivateKey = aaaa", maskKey: nil).serialize()
check(!plainS.contains("[Stealth]"), "serialize omits [Stealth] when plain")

// Round-trip: parse(serialize(x)) == x for both masked and plain.
let rt = try! StealthProfile.parse(p.serialize())
check(rt == p, "round-trips masked profile")
let rtPlain = try! StealthProfile.parse(pp.serialize())
check(rtPlain == pp, "round-trips plain profile")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test-parser.sh`
Expected: FAIL — `value of type 'StealthProfile' has no member 'serialize'` (compile error).

- [ ] **Step 3: Write minimal implementation**

Add to `Shared/StealthProfile.swift` inside `struct StealthProfile`, after `parse`:

```swift
    /// Reconstructs the raw StealthWG profile text: the wg-quick config, plus a
    /// trailing `[Stealth]` section carrying MaskKey when present. Inverse of
    /// `parse`, so `parse(serialize(x)) == x`.
    func serialize() -> String {
        var out = wgQuickConfig
        if let maskKey {
            out += "\n\n[Stealth]\nMaskKey = \(maskKey)\n"
        } else {
            out += "\n"
        }
        return out
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/test-parser.sh`
Expected: PASS — `ALL PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Shared/StealthProfile.swift Tests/StealthProfileTests.swift
git commit -m "StealthProfile: add serialize() with round-trip tests"
```

---

### Task 2: `TunnelManager.currentProfileText()`

**Files:**
- Modify: `App/TunnelManager.swift`

**Interfaces:**
- Consumes: `StealthProfile.serialize()` (Task 1), `manager.protocolConfiguration`.
- Produces: `func currentProfileText() -> String?` — raw text of the saved profile, or nil.

- [ ] **Step 1: Add the method**

Add to `App/TunnelManager.swift` inside `TunnelManager`, after `importProfile`:

```swift
    /// Reconstructs the saved profile's raw text (wg-quick + `[Stealth]`) for
    /// export, or nil when no profile is configured.
    func currentProfileText() -> String? {
        guard
            let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol,
            let config = proto.providerConfiguration?["wgQuickConfig"] as? String
        else {
            return nil
        }
        let maskKey = proto.providerConfiguration?["maskKey"] as? String
        return StealthProfile(wgQuickConfig: config, maskKey: maskKey).serialize()
    }
```

- [ ] **Step 2: Compile-check (deferred to Task 5 device build)**

No standalone compile step here; this is verified together with the UI in Task 5's unsigned device build. Proceed.

- [ ] **Step 3: Commit**

```bash
git add App/TunnelManager.swift
git commit -m "TunnelManager: expose current profile text for QR export"
```

---

### Task 3: `QRCodeView` (export rendering)

**Files:**
- Create: `App/QRCodeView.swift`

**Interfaces:**
- Consumes: a `String`.
- Produces: `QRCodeView(text:)` SwiftUI view; `static func qrImage(from:) -> UIImage?`.

- [ ] **Step 1: Create the view**

Create `App/QRCodeView.swift`:

```swift
import SwiftUI
import CoreImage.CIFilterBuiltins

/// Renders a string as a QR code. Uses CoreImage — no camera, works in the
/// Simulator. Used to export the current StealthWG profile to another device.
struct QRCodeView: View {
    let text: String

    var body: some View {
        VStack(spacing: 16) {
            if let image = Self.qrImage(from: text) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 280)
                    .accessibilityLabel("Profile QR code")
            } else {
                Text("Could not render QR code.")
                    .foregroundStyle(.red)
            }
            Text("Scan this on another device to import the profile.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    /// Generates a scaled, crisp QR image for `text`, or nil on failure.
    static func qrImage(from text: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add App/QRCodeView.swift
git commit -m "Add QRCodeView for exporting a profile as a QR code"
```

---

### Task 4: `QRScannerView` (import scanning)

**Files:**
- Create: `App/QRScannerView.swift`

**Interfaces:**
- Consumes: camera via AVFoundation.
- Produces: `QRScannerView(onScan:onError:)` SwiftUI view.

- [ ] **Step 1: Create the scanner**

Create `App/QRScannerView.swift`:

```swift
import SwiftUI
import AVFoundation

/// SwiftUI camera QR scanner. Calls `onScan` with the first decoded payload, or
/// `onError` with a readable message (permission denied / no camera / Simulator).
struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: ScannerViewController, context: Context) {}

    final class Coordinator: NSObject, ScannerViewControllerDelegate {
        let parent: QRScannerView
        init(_ parent: QRScannerView) { self.parent = parent }
        func didScan(_ code: String) { parent.onScan(code) }
        func didFail(_ message: String) { parent.onError(message) }
    }
}

protocol ScannerViewControllerDelegate: AnyObject {
    func didScan(_ code: String)
    func didFail(_ message: String)
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: ScannerViewControllerDelegate?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var handled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.configure() : self?.delegate?.didFail("Camera access denied.")
                }
            }
        default:
            delegate?.didFail("Camera access denied. Enable it in Settings, or paste the profile.")
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if session.inputs.isEmpty == false, !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    private func configure() {
        guard
            let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            delegate?.didFail("Camera unavailable. On a Simulator, paste the profile instead.")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            delegate?.didFail("Camera output unavailable.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.preview = preview

        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard
            !handled,
            let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            let value = obj.stringValue
        else { return }
        handled = true
        session.stopRunning()
        delegate?.didScan(value)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add App/QRScannerView.swift
git commit -m "Add QRScannerView camera scanner for QR import"
```

---

### Task 5: Wire ContentView + camera permission + device build

**Files:**
- Modify: `App/ContentView.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: `QRScannerView`, `QRCodeView`, `TunnelManager.currentProfileText()`, `TunnelManager.importProfile(_:)`.

- [ ] **Step 1: Add the camera usage description**

In `project.yml`, under the `StealthWG` target `settings.base`, add:

```yaml
        INFOPLIST_KEY_NSCameraUsageDescription: StealthWG scans QR codes to import a VPN profile.
```

- [ ] **Step 2: Add buttons + sheets to ContentView**

In `App/ContentView.swift`, add state at the top of `ContentView`:

```swift
    @State private var showScanner = false
    @State private var showExport = false
    @State private var scanError: String?
```

Replace the existing import `HStack` with one that adds the two QR buttons:

```swift
            HStack {
                Button("Import profile") {
                    Task { await tunnelManager.importProfile(profileText) }
                }
                .buttonStyle(.bordered)
                .disabled(profileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Scan QR") { scanError = nil; showScanner = true }
                    .buttonStyle(.bordered)

                Button("Show QR") { showExport = true }
                    .buttonStyle(.bordered)
                    .disabled(!tunnelManager.hasProfile)

                Spacer()
            }
```

Add a `scanError` display after the existing `lastError` block:

```swift
            if let scanError {
                Text(scanError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
```

Add the sheets to the outer `VStack` (after `.padding()`):

```swift
        .sheet(isPresented: $showScanner) {
            QRScannerView(
                onScan: { code in
                    showScanner = false
                    Task { await tunnelManager.importProfile(code) }
                },
                onError: { message in
                    scanError = message
                    showScanner = false
                }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showExport) {
            if let text = tunnelManager.currentProfileText() {
                QRCodeView(text: text)
            } else {
                Text("No profile to export.").padding()
            }
        }
```

- [ ] **Step 3: Regenerate the project**

Run: `xcodegen generate`
Expected: `Created project at .../StealthWG.xcodeproj`.

- [ ] **Step 4: Unsigned device build (compile verification)**

Run: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Re-run parser tests (guard against regressions)**

Run: `bash scripts/test-parser.sh`
Expected: `ALL PASSED`.

- [ ] **Step 6: Commit**

```bash
git add App/ContentView.swift project.yml
git commit -m "Wire QR scan/show into ContentView, add camera usage description"
```

---

## Self-Review

**Spec coverage:**
- Import scanner (AVFoundation) + Scan QR button + sheet → Tasks 4, 5. ✓
- Export via `serialize()` + `currentProfileText()` + `QRCodeView` + Show QR → Tasks 1, 2, 3, 5. ✓
- Camera permission via `INFOPLIST_KEY_NSCameraUsageDescription` → Task 5. ✓
- Reuses existing `importProfile`/`parse` path unchanged → Task 5 onScan. ✓
- Round-trip test in `scripts/test-parser.sh` → Task 1. ✓
- Unsigned device build verification → Task 5. ✓
- Permission-denied / Simulator handling → Task 4 (`onError`). ✓

**Placeholder scan:** No TODOs/TBDs; every code step is complete.

**Type/name consistency:** `serialize()` (Task 1) is consumed by `currentProfileText()` (Task 2) and round-trip tests (Task 1). `QRCodeView(text:)` and `QRScannerView(onScan:onError:)` signatures match their ContentView call sites (Task 5). `StealthProfile(wgQuickConfig:maskKey:)` memberwise init used in Tasks 1 and 2 is preserved (Global Constraints). `hasProfile`, `importProfile`, `currentProfileText` all exist on `TunnelManager`.
