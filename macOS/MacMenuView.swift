import SwiftUI
import AppKit
import NetworkExtension

/// Compact menu-bar panel: profile picker, status, connect toggle, live stats, and
/// setup (extension activation + launch at login).
struct MacMenuView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @EnvironmentObject private var systemExtension: SystemExtensionManager
    @Environment(\.openWindow) private var openWindow

    @State private var launchAtLogin = LoginItem.enabled

    private var status: NEVPNStatus { tunnelManager.status(of: tunnelManager.selectedID) }
    private var isActive: Bool {
        status == .connected || status == .connecting || status == .reasserting
    }
    private var selectedName: String? { tunnelManager.selectedProfile?.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status header
            HStack(spacing: 8) {
                Circle().fill(Theme.color(for: status)).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Theme.label(for: status))
                        .font(.system(.headline, design: .rounded))
                    if let name = selectedName {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if tunnelManager.profiles.isEmpty {
                Text("No profiles yet. Add one from Manage profiles.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("", selection: $tunnelManager.selectedID) {
                    ForEach(tunnelManager.profiles) { p in
                        Text(p.name).tag(Optional(p.id))
                    }
                }
                .labelsHidden()

                if let s = tunnelManager.stats, tunnelManager.connectedID == tunnelManager.selectedID {
                    HStack(spacing: 14) {
                        Text("↓ \(StatsView.rate(s.rxRate))")
                        Text("↑ \(StatsView.rate(s.txRate))")
                    }
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    if let ep = s.activeEndpoint {
                        Text(ep).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }

                Button {
                    guard let id = tunnelManager.selectedID else { return }
                    isActive ? tunnelManager.disconnect(id: id) : tunnelManager.connect(id: id)
                } label: {
                    Label(isActive ? "Disconnect" : "Connect",
                          systemImage: isActive ? "shield.slash" : "shield.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(tunnelManager.selectedID == nil)
            }

            Divider()

            // Setup: extension activation (until done) + launch at login
            if !systemExtension.isActivated {
                Button {
                    systemExtension.activate()
                } label: {
                    Label("Enable VPN extension", systemImage: "puzzlepiece.extension")
                }
                if !systemExtension.statusMessage.isEmpty {
                    Text(systemExtension.statusMessage)
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(isOn: $launchAtLogin) {
                Label("Launch at login", systemImage: "power")
            }
            .toggleStyle(.checkbox)
            .onChange(of: launchAtLogin) { on in
                do { try LoginItem.set(on) } catch { launchAtLogin = LoginItem.enabled }
            }

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "manage")
            } label: {
                Label("Manage profiles…", systemImage: "list.bullet.rectangle")
            }
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit StealthWG", systemImage: "power.circle")
            }
        }
        .buttonStyle(.plain)
        .padding(14).frame(width: 280)
        .onAppear { launchAtLogin = LoginItem.enabled }
    }
}
