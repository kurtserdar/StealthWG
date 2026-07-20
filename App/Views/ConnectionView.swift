import SwiftUI
import NetworkExtension

/// Home screen: the selected profile's connect hero + live stats, plus access to
/// the profile list (switch) and this profile's detail (edit/QR/delete).
struct ConnectionView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @State private var showProfiles = false
    @State private var showDetail = false

    private var selected: TunnelProfile? { tunnelManager.selectedProfile }
    private var status: NEVPNStatus { tunnelManager.status(of: tunnelManager.selectedID) }
    private var isActive: Bool {
        status == .connected || status == .connecting || status == .reasserting
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 10) {
                Button { showDetail = true } label: {
                    HStack {
                        Image(systemName: "lock.shield")
                        Text(selected?.name ?? "StealthWG").lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                Button { showProfiles = true } label: {
                    Image(systemName: "list.bullet")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            ConnectDial(status: status) {
                guard let id = tunnelManager.selectedID else { return }
                isActive ? tunnelManager.disconnect(id: id) : tunnelManager.connect(id: id)
            }

            Text(Theme.label(for: status))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(Theme.color(for: status))
                .contentTransition(.opacity)

            if let stats = tunnelManager.stats, tunnelManager.connectedID == tunnelManager.selectedID {
                StatsView(stats: stats)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Spacer(minLength: 0)

            if let error = tunnelManager.lastError {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding()
        .animation(.easeInOut, value: status)
        .sheet(isPresented: $showProfiles) {
            ProfilesListView().environmentObject(tunnelManager)
        }
        .sheet(isPresented: $showDetail) {
            if let selected {
                NavigationStack {
                    ProfileDetailView(profile: selected).environmentObject(tunnelManager)
                }
            }
        }
    }
}
