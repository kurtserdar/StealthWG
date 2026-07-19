import Foundation

/// Byte counters and handshake age parsed from a WireGuard runtime configuration
/// (UAPI text). Summed across peers.
struct RuntimeStats: Equatable {
    var rxBytes: Int64
    var txBytes: Int64
    var lastHandshakeSeconds: Int
}

func parseRuntimeStats(_ uapi: String) -> RuntimeStats {
    var rx: Int64 = 0
    var tx: Int64 = 0
    for line in uapi.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("rx_bytes=") {
            rx += Int64(t.dropFirst("rx_bytes=".count)) ?? 0
        } else if t.hasPrefix("tx_bytes=") {
            tx += Int64(t.dropFirst("tx_bytes=".count)) ?? 0
        }
    }
    return RuntimeStats(rxBytes: rx, txBytes: tx,
                        lastHandshakeSeconds: lastHandshakeSeconds(fromRuntimeConfig: uapi))
}
