import SwiftUI
import AppKit
import NetworkExtension

/// Compact menu-bar panel: profile picker, status, connect toggle, live stats.
struct MacMenuView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @EnvironmentObject private var systemExtension: SystemExtensionManager
    @Environment(\.openWindow) private var openWindow

    private var status: NEVPNStatus { tunnelManager.status(of: tunnelManager.selectedID) }
    private var isActive: Bool {
        status == .connected || status == .connecting || status == .reasserting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(Theme.color(for: status)).frame(width: 10, height: 10)
                Text(Theme.label(for: status))
                    .font(.system(.headline, design: .rounded))
                Spacer()
            }

            if !tunnelManager.profiles.isEmpty {
                Picker("", selection: $tunnelManager.selectedID) {
                    ForEach(tunnelManager.profiles) { p in
                        Text(p.name).tag(Optional(p.id))
                    }
                }
                .labelsHidden()
            }

            if let s = tunnelManager.stats, tunnelManager.connectedID == tunnelManager.selectedID {
                Text("↓ \(StatsView.rate(s.rxRate))   ↑ \(StatsView.rate(s.txRate))")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                if let ep = s.activeEndpoint {
                    Text(ep).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
            }

            Button(isActive ? "Disconnect" : "Connect") {
                guard let id = tunnelManager.selectedID else { return }
                isActive ? tunnelManager.disconnect(id: id) : tunnelManager.connect(id: id)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .disabled(tunnelManager.selectedID == nil)

            Divider()
            Button("Enable VPN extension") { systemExtension.activate() }
            if !systemExtension.statusMessage.isEmpty {
                Text(systemExtension.statusMessage)
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("Manage profiles…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "manage")
            }
            Button("Quit StealthWG") { NSApplication.shared.terminate(nil) }
        }
        .padding(14).frame(width: 280)
    }
}
