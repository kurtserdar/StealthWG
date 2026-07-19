import SwiftUI

/// Live connection stats: throughput, duration, handshake, and the active
/// endpoint with a fallback badge when a backup endpoint is in use.
struct StatsView: View {
    let stats: ConnectionStats
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                statCard("Download", value: Self.rate(stats.rxRate), sub: Self.bytes(stats.rxBytes), system: "arrow.down")
                statCard("Upload", value: Self.rate(stats.txRate), sub: Self.bytes(stats.txBytes), system: "arrow.up")
            }
            HStack(spacing: 12) {
                statCard("Duration", value: durationText, sub: "connected", system: "clock")
                statCard("Handshake", value: handshakeText, sub: "last", system: "checkmark.seal")
            }
            endpointRow
        }
        .onReceive(ticker) { now = $0 }
    }

    private func statCard(_ title: String, value: String, sub: String, system: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: system)
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(sub).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var endpointRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
            Text(stats.activeEndpoint ?? "—")
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if stats.isFallback {
                badge("FALLBACK", tint: Theme.amber)
            }
            badge("MASK ON", tint: Theme.accent)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(.caption2, design: .rounded).weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }

    private var durationText: String {
        guard let since = stats.connectedSince else { return "—" }
        let s = Int(max(0, now.timeIntervalSince(since)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    private var handshakeText: String {
        guard stats.lastHandshakeSeconds > 0 else { return "—" }
        let ago = Int(Date().timeIntervalSince1970) - stats.lastHandshakeSeconds
        return ago < 0 ? "now" : "\(ago)s ago"
    }

    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .binary)
    }
    static func rate(_ bps: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .binary) + "/s"
    }
}
