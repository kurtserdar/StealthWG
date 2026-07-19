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
