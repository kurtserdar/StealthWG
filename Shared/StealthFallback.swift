import Foundation

/// What the fallback loop should do next for the current endpoint.
enum FallbackAction: Equatable {
    case connected
    case keepWaiting
    case tryNext(index: Int)
    case exhausted
}

/// Decides, from observed handshake state and elapsed time, whether to keep
/// waiting on the current endpoint, advance to the next, or stop. Pure logic so
/// it can be unit-tested off-device.
struct FallbackPlan {
    let endpointCount: Int
    let perEndpointTimeout: TimeInterval

    func decide(index: Int, elapsed: TimeInterval, handshaked: Bool) -> FallbackAction {
        if handshaked { return .connected }
        if elapsed < perEndpointTimeout { return .keepWaiting }
        let next = index + 1
        return next < endpointCount ? .tryNext(index: next) : .exhausted
    }
}

/// An endpoint together with the transport used to reach it.
struct EndpointTarget: Equatable {
    let hostPort: String
    let transport: String
}

/// Parses one `[Stealth] Endpoints` entry into host:port + transport. An entry
/// may carry a `quic://` or `mask://` scheme to override the profile transport
/// for that endpoint (mixed-transport fallback, e.g. try QUIC:443 then fall back
/// to a mask endpoint). A bare `host:port` inherits `defaultTransport`.
func parseEndpointTarget(_ raw: String, defaultTransport: String) -> EndpointTarget {
    let s = raw.trimmingCharacters(in: .whitespaces)
    for scheme in ["quic", "mask"] {
        let prefix = scheme + "://"
        if s.lowercased().hasPrefix(prefix) {
            return EndpointTarget(hostPort: String(s.dropFirst(prefix.count)), transport: scheme)
        }
    }
    return EndpointTarget(hostPort: s, transport: defaultTransport)
}

/// Parses `last_handshake_time_sec=<n>` from a WireGuard runtime configuration
/// (UAPI text). Returns 0 when absent.
func lastHandshakeSeconds(fromRuntimeConfig text: String) -> Int {
    for line in text.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("last_handshake_time_sec=") {
            let value = trimmed.dropFirst("last_handshake_time_sec=".count)
            return Int(value) ?? 0
        }
    }
    return 0
}
