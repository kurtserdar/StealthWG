import Foundation

/// One endpoint to probe, with its transport and split host/port.
struct DiagnosticTarget: Equatable {
    let hostPort: String
    let transport: String   // "mask" | "quic"

    /// Host part (everything before the last colon), or the whole string if none.
    var host: String {
        guard let i = hostPort.lastIndex(of: ":") else { return hostPort }
        return String(hostPort[..<i])
    }
    /// Port after the last colon, or 0 if absent/invalid.
    var port: Int {
        guard let i = hostPort.lastIndex(of: ":") else { return 0 }
        return Int(hostPort[hostPort.index(after: i)...]) ?? 0
    }
}

/// Outcome of probing one target.
enum DiagnosticStatus: Equatable {
    case pending
    case reachableQUIC(rttMillis: Int)
    case reachableViaTunnel
    case timeout
    case unreachable(String)
    case dnsFailed
    case needsTunnel

    /// SF Symbol for the row.
    var symbol: String {
        switch self {
        case .pending: return "circle.dotted"
        case .reachableQUIC, .reachableViaTunnel: return "checkmark.circle.fill"
        case .timeout: return "clock.badge.exclamationmark"
        case .unreachable: return "xmark.circle.fill"
        case .dnsFailed: return "questionmark.circle.fill"
        case .needsTunnel: return "info.circle"
        }
    }

    /// Short human label.
    var label: String {
        switch self {
        case .pending: return "Testing…"
        case .reachableQUIC(let rtt): return "Reachable · \(rtt) ms"
        case .reachableViaTunnel: return "Reachable (live tunnel)"
        case .timeout: return "Timed out"
        case .unreachable(let reason): return "Unreachable · \(reason)"
        case .dnsFailed: return "Host not found"
        case .needsTunnel: return "Needs tunnel (mask)"
        }
    }
}

struct DiagnosticResult: Equatable, Identifiable {
    let target: DiagnosticTarget
    var status: DiagnosticStatus
    var id: String { target.hostPort }
}

/// Builds probe targets from a profile's endpoints (reuses parseEndpointTarget).
func diagnosticTargets(for profile: StealthProfile) -> [DiagnosticTarget] {
    profile.endpoints.map {
        let t = parseEndpointTarget($0, defaultTransport: profile.transport)
        return DiagnosticTarget(hostPort: t.hostPort, transport: t.transport)
    }
}

/// Upgrades a mask endpoint's `needsTunnel` to `reachableViaTunnel` when it is the
/// live active endpoint with a recent handshake. Pure; used after probing.
func applyLiveStatus(_ results: [DiagnosticResult], activeEndpoint: String?, handshakeRecent: Bool) -> [DiagnosticResult] {
    guard let active = activeEndpoint, handshakeRecent else { return results }
    return results.map { r in
        if r.status == .needsTunnel, r.target.hostPort == active {
            var up = r; up.status = .reachableViaTunnel; return up
        }
        return r
    }
}

/// Human-readable multi-line summary for Copy.
func diagnosticsSummary(_ results: [DiagnosticResult]) -> String {
    results
        .map { "\($0.target.transport.uppercased())  \($0.target.hostPort)  —  \($0.status.label)" }
        .joined(separator: "\n")
}
