import SwiftUI
import NetworkExtension

/// Home screen shown once a profile exists: a profile chip, the connect dial,
/// the masking status, and — when connected — live stats.
struct ConnectionView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @Binding var showProfile: Bool

    private var isActive: Bool {
        switch tunnelManager.status {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            Button { showProfile = true } label: {
                HStack {
                    Image(systemName: "lock.shield")
                    Text("StealthWG profile")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            ConnectDial(status: tunnelManager.status) {
                isActive ? tunnelManager.disconnect() : tunnelManager.connect()
            }

            Text(Theme.label(for: tunnelManager.status))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(Theme.color(for: tunnelManager.status))
                .contentTransition(.opacity)

            if let stats = tunnelManager.stats, tunnelManager.status == .connected {
                StatsView(stats: stats)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Spacer(minLength: 0)

            if let error = tunnelManager.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .animation(.easeInOut, value: tunnelManager.status)
    }
}
