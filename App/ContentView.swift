import SwiftUI
import NetworkExtension

struct ContentView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @State private var profileText = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("StealthWG")
                .font(.largeTitle.bold())

            statusBadge

            profileEditor

            HStack {
                Button("Import profile") {
                    Task { await tunnelManager.importProfile(profileText) }
                }
                .buttonStyle(.bordered)
                .disabled(profileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }

            connectButton
                .disabled(!tunnelManager.hasProfile)

            if let error = tunnelManager.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding()
    }

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
            Text(statusText)
                .font(.headline)
        }
    }

    private var profileEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Profile (.conf with a [Stealth] section)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $profileText)
                .font(.system(.footnote, design: .monospaced))
                .frame(height: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.secondary.opacity(0.3))
                )
        }
    }

    private var connectButton: some View {
        Button {
            if isActive {
                tunnelManager.disconnect()
            } else {
                tunnelManager.connect()
            }
        } label: {
            Text(isActive ? "Disconnect" : "Connect")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(isActive ? .red : .accentColor)
    }

    private var isActive: Bool {
        switch tunnelManager.status {
        case .connected, .connecting, .reasserting:
            return true
        default:
            return false
        }
    }

    private var statusText: String {
        switch tunnelManager.status {
        case .invalid: return "Not configured"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        @unknown default: return "Unknown"
        }
    }

    private var statusColor: Color {
        switch tunnelManager.status {
        case .connected: return .green
        case .connecting, .reasserting, .disconnecting: return .orange
        default: return .gray
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(TunnelManager())
}
