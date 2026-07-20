import SwiftUI

/// "Test server": probes a profile's endpoints for reachability and shows which
/// transport gets through. App-side; most accurate while disconnected.
struct DiagnosticsView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @StateObject private var runner = DiagnosticsRunner()
    let profile: StealthProfile

    var body: some View {
        List {
            Section {
                Button {
                    runner.run(
                        for: profile,
                        activeEndpoint: tunnelManager.stats?.activeEndpoint,
                        handshakeRecent: recentHandshake(tunnelManager.stats?.lastHandshakeSeconds))
                } label: {
                    Label(runner.isRunning ? "Testing…" : "Run test", systemImage: "bolt.horizontal.circle")
                }
                .disabled(runner.isRunning)
            } footer: {
                Text("QUIC endpoints are tested directly. Mask endpoints can only be confirmed by a live VPN handshake. Most accurate while disconnected.")
            }

            if !runner.results.isEmpty {
                Section("Endpoints") {
                    ForEach(runner.results) { result in
                        HStack(spacing: 10) {
                            Image(systemName: result.status.symbol).foregroundStyle(color(for: result.status))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.target.hostPort).font(.system(.footnote, design: .monospaced))
                                Text(result.status.label).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(result.target.transport.uppercased())
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Test server")
        .inlineNavTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Clipboard.copy(diagnosticsSummary(runner.results)) } label: {
                    Image(systemName: "doc.on.doc")
                }.disabled(runner.results.isEmpty)
            }
        }
    }

    private func recentHandshake(_ secs: Int?) -> Bool {
        guard let secs, secs > 0 else { return false }
        return Date().timeIntervalSince1970 - Double(secs) < 180
    }

    private func color(for status: DiagnosticStatus) -> Color {
        switch status {
        case .reachableQUIC, .reachableViaTunnel: return .green
        case .timeout, .unreachable, .dnsFailed: return .red
        case .needsTunnel, .pending: return .secondary
        }
    }
}
