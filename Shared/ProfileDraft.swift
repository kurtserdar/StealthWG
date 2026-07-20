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
    var transport = StealthProfile.defaultTransport
    var sni = ""

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
        if t(transport) != StealthProfile.defaultTransport && !t(transport).isEmpty {
            lines.append("Transport = \(t(transport))")
        }
        if !t(sni).isEmpty { lines.append("SNI = \(t(sni))") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reverse of `build()` for our profile shape: line-scans the wg-quick config
    /// into editable fields so an existing profile can be edited in the form.
    static func from(_ profile: StealthProfile) -> ProfileDraft {
        func field(_ key: String) -> String {
            for line in profile.wgQuickConfig.split(separator: "\n") {
                let s = line.trimmingCharacters(in: .whitespaces)
                guard let eq = s.firstIndex(of: "=") else { continue }
                if s[..<eq].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame {
                    return s[s.index(after: eq)...].trimmingCharacters(in: .whitespaces)
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
        d.transport = profile.transport
        d.sni = profile.sni ?? ""
        return d
    }
}

/// Default display name for an imported profile: the endpoint host (no port).
func defaultProfileName(for profile: StealthProfile) -> String {
    guard let ep = profile.endpoints.first else { return "StealthWG" }
    if let colon = ep.lastIndex(of: ":") { return String(ep[..<colon]) }
    return ep
}
