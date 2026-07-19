import SwiftUI

/// Shows the parsed profile and offers export (QR), replace, and delete.
struct ProfileDetailView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @State private var showQR = false
    @State private var showReplace = false

    private var summary: ProfileSummary? {
        guard
            let text = tunnelManager.currentProfileText(),
            let profile = try? StealthProfile.parse(text)
        else { return nil }
        return ProfileSummary.from(profile)
    }

    var body: some View {
        NavigationStack {
            List {
                if let s = summary {
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
                                if i == 0 {
                                    Text("primary").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section("Masking") {
                        Label(s.maskingOn ? "On" : "Off",
                              systemImage: s.maskingOn ? "checkmark.shield.fill" : "xmark.shield")
                            .foregroundStyle(s.maskingOn ? Theme.accent : .secondary)
                    }
                }
                Section {
                    Button { showQR = true } label: { Label("Show QR", systemImage: "qrcode") }
                    Button { showReplace = true } label: {
                        Label("Replace profile", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button(role: .destructive) {
                        Task { await tunnelManager.deleteProfile(); dismiss() }
                    } label: { Label("Delete profile", systemImage: "trash") }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showQR) {
                if let text = tunnelManager.currentProfileText() {
                    QRCodeView(text: text)
                } else {
                    Text("No profile to export.").padding()
                }
            }
            .sheet(isPresented: $showReplace) {
                AddProfileView(onComplete: { showReplace = false })
                    .environmentObject(tunnelManager)
            }
        }
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
