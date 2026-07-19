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
