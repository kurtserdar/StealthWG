import SwiftUI
import NetworkExtension

/// Shows one profile: connect/disconnect, parsed summary, edit, export (QR), delete.
struct ProfileDetailView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @Environment(\.dismiss) private var dismiss
    let profile: TunnelProfile

    @State private var showQR = false
    @State private var showEdit = false

    /// Live profile from the manager so the VPN-option toggles reflect saved state.
    private var current: TunnelProfile { tunnelManager.profiles.first { $0.id == profile.id } ?? profile }
    private var summary: ProfileSummary { ProfileSummary.from(current.profile) }
    private var status: NEVPNStatus { tunnelManager.status(of: profile.id) }
    private var isActive: Bool {
        status == .connected || status == .connecting || status == .reasserting
    }

    var body: some View {
        List {
                Section {
                    Button {
                        tunnelManager.selectedID = profile.id
                        isActive ? tunnelManager.disconnect(id: profile.id) : tunnelManager.connect(id: profile.id)
                    } label: {
                        Label(isActive ? "Disconnect" : "Connect",
                              systemImage: isActive ? "stop.circle" : "play.circle")
                    }
                    .tint(isActive ? .red : Theme.accent)
                }

                let s = summary
                Section("Interface") {
                    row("Address", s.address)
                    row("DNS", s.dns)
                    row("MTU", s.mtu)
                }
                Section("Peer") {
                    row("Public key", s.peerPublicKey)
                    row("Allowed IPs", s.allowedIPs)
                }
                Section("Endpoints") {
                    ForEach(Array(s.endpoints.enumerated()), id: \.offset) { i, ep in
                        HStack {
                            Text(ep).font(.system(.footnote, design: .monospaced))
                            Spacer()
                            if i == 0 { Text("primary").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section("Masking") {
                    Label(s.maskingOn ? "On" : "Off",
                          systemImage: s.maskingOn ? "checkmark.shield.fill" : "xmark.shield")
                        .foregroundStyle(s.maskingOn ? Theme.accent : .secondary)
                }
                Section("Transport") {
                    Label(s.transport == "quic" ? "QUIC (HTTPS/443)" : "UDP mask",
                          systemImage: s.transport == "quic" ? "bolt.horizontal.circle.fill" : "waveform")
                        .foregroundStyle(Theme.accent)
                    if s.transport == "quic", let sni = s.sni {
                        HStack {
                            Text("SNI").foregroundStyle(.secondary)
                            Spacer()
                            Text(sni).font(.system(.footnote, design: .monospaced))
                        }
                    }
                }
                Section("VPN options") {
                    Toggle("Connect on demand", isOn: Binding(
                        get: { current.onDemand },
                        set: { v in Task { await tunnelManager.setOnDemand(id: profile.id, enabled: v) } }))
                    Text("Automatically connect and stay on; block traffic if the VPN drops.")
                        .font(.caption2).foregroundStyle(.secondary)

                    Toggle("Kill switch (route all traffic)", isOn: Binding(
                        get: { current.killSwitch },
                        set: { v in Task { await tunnelManager.setKillSwitch(id: profile.id, enabled: v) } }))
                    Text("Send all traffic through the tunnel to prevent leaks.")
                        .font(.caption2).foregroundStyle(.secondary)

                    if current.killSwitch {
                        Toggle("Allow local network", isOn: Binding(
                            get: { current.allowLocal },
                            set: { v in Task { await tunnelManager.setAllowLocal(id: profile.id, enabled: v) } }))
                        Text("Keep printers, file shares, and other LAN devices reachable.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .tint(Theme.accent)
                Section {
                    Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                    Button { showQR = true } label: { Label("Show QR", systemImage: "qrcode") }
                    Button(role: .destructive) {
                        Task { await tunnelManager.deleteProfile(id: profile.id); dismiss() }
                    } label: { Label("Delete profile", systemImage: "trash") }
                }
            }
            .navigationTitle(current.name)
            .inlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showQR) {
                if let text = tunnelManager.profileText(id: profile.id) {
                    QRCodeView(text: text)
                } else {
                    Text("No profile to export.").padding()
                }
            }
            .sheet(isPresented: $showEdit) {
                NavigationStack {
                    ProfileFormView(editing: profile, onComplete: { showEdit = false })
                        .environmentObject(tunnelManager)
                }
            }
            .onAppear { tunnelManager.selectedID = profile.id }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—")
                .font(.system(.footnote, design: .monospaced))
                .multilineTextAlignment(.trailing)
        }
    }
}
