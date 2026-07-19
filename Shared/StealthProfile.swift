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

    enum ParseError: Error, Equatable {
        case emptyConfiguration
    }

    /// Splits a raw profile into its wg-quick config and the optional mask key.
    static func parse(_ raw: String) throws -> StealthProfile {
        var wgLines: [String] = []
        var maskKey: String?
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
                // Inside [Stealth]: capture MaskKey, drop every other line.
                if let value = value(of: "MaskKey", in: trimmed) {
                    maskKey = value
                }
                continue
            }

            wgLines.append(line)
        }

        let wgConfig = wgLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wgConfig.isEmpty else {
            throw ParseError.emptyConfiguration
        }
        return StealthProfile(wgQuickConfig: wgConfig, maskKey: maskKey)
    }

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

    /// Returns the value of `key = value` (case-insensitive key), or nil.
    private static func value(of key: String, in line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let lineKey = line[..<equals].trimmingCharacters(in: .whitespaces)
        guard lineKey.caseInsensitiveCompare(key) == .orderedSame else { return nil }
        let lineValue = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return lineValue.isEmpty ? nil : lineValue
    }
}
