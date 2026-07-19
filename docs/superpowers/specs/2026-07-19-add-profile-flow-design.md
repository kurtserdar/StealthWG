# Add-profile flow — 4 sources + full editor — design

**Date:** 2026-07-19
**Status:** Approved, ready for implementation planning

## Goal

Replace the single paste box behind "Add profile" with a capable, WireGuard-app-style
flow offering four ways to add a profile — **Scan QR, Paste, Import file, Create
from scratch** — where "from scratch" is a full editor with smart defaults, a
collapsible Advanced section, and client keypair generation (or manual entry)
with the derived public key shown for copying.

## Background (current code)

- `App/Views/ProfileSetupView.swift` — one sheet: paste `TextEditor` + "Scan QR".
- `App/TunnelManager.swift` — `importProfile(_ raw:)` parses + saves; this stays
  the single ingest path for every source.
- `Shared/StealthProfile.swift` — `parse`/`serialize`, `endpoints`, `maskKey`.
- `App/Views/QRScannerView.swift` — camera scanner (reused).
- Verified: CryptoKit `Curve25519.KeyAgreement` public-key derivation matches
  `wg pubkey` exactly (test vector `+CzRH…kaRko=` → `NF8+…M2A=`), and swiftc
  compiles CryptoKit, so key logic is unit-testable.

## Architecture

### `AddProfileView` (method chooser)

A sheet with a `NavigationStack` listing the four methods (icon + one-line
description each):

1. **Scan QR** → `QRScannerView` → on scan, `importProfile` → dismiss the sheet.
2. **Paste** → a `TextEditor` screen → `importProfile` → dismiss.
3. **Import file** → SwiftUI `.fileImporter` (UTType `.item`/`.data`, `.conf`) →
   read the file text → `importProfile` → dismiss.
4. **Create from scratch** → `ProfileFormView`.

Presented from the empty state ("Add profile") and from `ProfileDetailView`
("Replace profile"). Replaces the old `ProfileSetupView` (its paste + scan fold
into `AddProfileView`).

### `ProfileFormView` (full editor)

A `Form` bound to a `ProfileDraft`, grouped:

- **Interface**
  - Private Key (monospace `TextField`) + **Generate** button. Below it a
    read-only **Public Key** row (derived live from the private key) with a
    **Copy** button and the hint "add this to your server as a peer".
  - Addresses (default `10.0.0.2/32`), DNS (default `1.1.1.1`).
  - *Advanced (DisclosureGroup):* MTU (default `1280`).
- **Peer (server)**
  - Public Key (server), Endpoint (`host:port`), Allowed IPs (default `0.0.0.0/0`).
  - *Advanced:* Persistent Keepalive (default `25`), Preshared Key (WG's own,
    optional) + **Generate**, and add-more **fallback endpoints** (→ `[Stealth]
    Endpoints`).
- **Masking**
  - Mask Key + **Generate** (base64 32 bytes).

Toolbar **Save**: `draft.build()` assembles the profile text → `importProfile` →
dismiss. Save is disabled until the minimum viable fields are present (private
key, server public key, endpoint, mask key).

### `ProfileDraft` (pure model, unit-tested) — `Shared/ProfileDraft.swift`

```
struct ProfileDraft {
    var privateKey, address, dns, mtu: String
    var serverPublicKey, endpoint, allowedIPs, keepalive, presharedKey: String
    var fallbackEndpoints: [String]
    var maskKey: String

    static func defaults() -> ProfileDraft            // smart defaults filled in
    var derivedPublicKey: String?                     // CryptoKit, nil if priv invalid
    mutating func generateKeypair()                   // CryptoKit random X25519
    static func randomBase64Key() -> String           // 32 random bytes, base64 (mask/PSK)
    func build() -> String                            // wg-quick + [Stealth]
}
```

`build()` emits only the lines that are set (PresharedKey, DNS, MTU, keepalive,
`[Stealth] Endpoints` are optional), producing text that `StealthProfile.parse`
already accepts. Key derivation uses
`Curve25519.KeyAgreement.PrivateKey(rawRepresentation:).publicKey`. Random keys
use `SymmetricKey(size: .bits256)` / `Curve25519` raw representation.

## Data flow

```
AddProfileView ─┬─ Scan QR ───────────► importProfile(text)
                ├─ Paste ─────────────► importProfile(text)
                ├─ Import file ───────► importProfile(fileText)
                └─ Create from scratch ► ProfileFormView(draft) ► draft.build() ► importProfile(text)
```

Every path ends at the existing `TunnelManager.importProfile` (unchanged parse/save).

## Files

- Create: `Shared/ProfileDraft.swift`, `App/Views/AddProfileView.swift`,
  `App/Views/ProfileFormView.swift`.
- Modify: `App/ContentView.swift` (present `AddProfileView`),
  `App/Views/ProfileDetailView.swift` ("Replace" → `AddProfileView`),
  `scripts/test-parser.sh` (+ `ProfileDraft.swift`),
  `Tests/StealthProfileTests.swift` (draft tests).
- Remove: `App/Views/ProfileSetupView.swift` (folded into `AddProfileView`).

## Testing

- **Pure logic** (`scripts/test-parser.sh`, swiftc + CryptoKit): `derivedPublicKey`
  matches the known vector; `build()` output contains the expected sections/lines
  and round-trips through `StealthProfile.parse` (endpoints, mask key preserved);
  optional lines omitted when empty; `randomBase64Key()` yields 44-char base64.
- **UI + fileImporter + camera**: unsigned device build
  (`xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO`) + on-device test (generate a
  keypair, copy the public key, save, connect).

## Non-goals (YAGNI)

- Multi-profile gallery/switching.
- Editing an existing profile by pre-filling the form (Replace creates anew for
  now).
- Generating the *server* keypair in-app (the gateway owns server keys).
- Password/encryption on QR or exported profiles.

## Security notes

- Private key and mask/preshared keys are generated on-device with CryptoKit and
  never leave the device except inside the profile the user saves. The derived
  public key is safe to display/copy (it is public by design).
- No new persistence; the assembled profile still lives only in
  `providerConfiguration` after import.
