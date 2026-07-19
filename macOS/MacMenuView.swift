import SwiftUI
import AppKit
import NetworkExtension

/// Compact menu-bar panel: status, connect toggle, live endpoint/throughput.
struct MacMenuView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @Environment(\.openWindow) private var openWindow

    private var isActive: Bool {
        switch tunnelManager.status {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(Theme.color(for: tunnelManager.status)).frame(width: 10, height: 10)
                Text(Theme.label(for: tunnelManager.status))
                    .font(.system(.headline, design: .rounded))
                Spacer()
            }
            if let s = tunnelManager.stats, tunnelManager.status == .connected {
                Text("↓ \(StatsView.rate(s.rxRate))   ↑ \(StatsView.rate(s.txRate))")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                if let ep = s.activeEndpoint {
                    Text(ep).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Button(isActive ? "Disconnect" : "Connect") {
                isActive ? tunnelManager.disconnect() : tunnelManager.connect()
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .disabled(!tunnelManager.hasProfile)
            Divider()
            Button("Manage profile…") {
                // An accessory (menu-bar) app must activate itself, otherwise the
                // window opens behind other apps and appears to do nothing.
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "manage")
            }
            Button("Quit StealthWG") { NSApplication.shared.terminate(nil) }
        }
        .padding(14).frame(width: 260)
    }
}
