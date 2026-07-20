import Foundation

/// A StealthWG profile: a standard wg-quick configuration plus an optional
/// obfuscation key carried in a `[Stealth]` section.
///
/// The `[Stealth]` section is StealthWG-specific and is stripped out here so the
/// remaining `wgQuickConfig` parses cleanly with WireGuardKit's own parser. The
/// `[Peer] Endpoint` points at the gateway's mask port; `maskKey` is the PSK the
/// masking bind uses.
struct StealthProfile: Equatable {
    /// Standard wg-quick config with the `[Stealth]` section removed.
    let wgQuickConfig: String
    /// Base64 PSK from `[Stealth] MaskKey`, or nil for plain WireGuard.
    let maskKey: String?
    /// Ordered gateway endpoints to try (primary first). May be empty.
    let endpoints: [String]
    /// Transport from `[Stealth] Transport`: `"mask"` (UDP mask, default) or `"quic"`.
    let transport: String
    /// TLS SNI presented by the QUIC transport, from `[Stealth] SNI`, or nil.
    let sni: String?

    /// The default transport when a profile omits `[Stealth] Transport`.
    static let defaultTransport = "mask"

    init(
        wgQuickConfig: String,
        maskKey: String?,
        endpoints: [String] = [],
        transport: String = StealthProfile.defaultTransport,
        sni: String? = nil
    ) {
        self.wgQuickConfig = wgQuickConfig
        self.maskKey = maskKey
        self.endpoints = endpoints
        self.transport = transport
        self.sni = sni
    }

    enum ParseError: Error, Equatable {
        case emptyConfiguration
    }

    /// Splits a raw profile into its wg-quick config and the optional mask key.
    static func parse(_ raw: String) throws -> StealthProfile {
        var wgLines: [String] = []
        var maskKey: String?
        var peerEndpoint: String?
        var stealthEndpoints: [String] = []
        var transport = StealthProfile.defaultTransport
        var sni: String?
        var inStealthSection = false

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inStealthSection = trimmed.lowercased() == "[stealth]"
                if inStealthSection {
                    continue // drop the [Stealth] header itself
                }
            }

            if inStealthSection {
                // Inside [Stealth]: capture MaskKey and Endpoints, drop the rest.
                if let value = value(of: "MaskKey", in: trimmed) {
                    maskKey = value
                }
                if let value = value(of: "Endpoints", in: trimmed) {
                    stealthEndpoints = value
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
                if let value = value(of: "Transport", in: trimmed) {
                    transport = value.lowercased()
                }
                if let value = value(of: "SNI", in: trimmed) {
                    sni = value
                }
                continue
            }

            if peerEndpoint == nil, let value = value(of: "Endpoint", in: trimmed) {
                peerEndpoint = value
            }

            wgLines.append(line)
        }

        let wgConfig = wgLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wgConfig.isEmpty else {
            throw ParseError.emptyConfiguration
        }
        var ordered: [String] = []
        for ep in ([peerEndpoint].compactMap { $0 } + stealthEndpoints) where !ordered.contains(ep) {
            ordered.append(ep)
        }
        return StealthProfile(
            wgQuickConfig: wgConfig,
            maskKey: maskKey,
            endpoints: ordered,
            transport: transport,
            sni: sni
        )
    }

    /// Reconstructs the raw StealthWG profile text: the wg-quick config, plus a
    /// trailing `[Stealth]` section carrying MaskKey when present. Inverse of
    /// `parse`, so `parse(serialize(x)) == x`.
    func serialize() -> String {
        var out = wgQuickConfig
        var stealth = ""
        if let maskKey {
            stealth += "MaskKey = \(maskKey)\n"
        }
        if endpoints.count > 1 {
            stealth += "Endpoints = \(endpoints.joined(separator: ", "))\n"
        }
        if transport != StealthProfile.defaultTransport {
            stealth += "Transport = \(transport)\n"
        }
        if let sni {
            stealth += "SNI = \(sni)\n"
        }
        if stealth.isEmpty {
            out += "\n"
        } else {
            out += "\n\n[Stealth]\n" + stealth
        }
        return out
    }

    /// Returns the value of `key = value` (case-insensitive key), or nil.
    private static func value(of key: String, in line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let lineKey = line[..<equals].trimmingCharacters(in: .whitespaces)
        guard lineKey.caseInsensitiveCompare(key) == .orderedSame else { return nil }
        let lineValue = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return lineValue.isEmpty ? nil : lineValue
    }
}
