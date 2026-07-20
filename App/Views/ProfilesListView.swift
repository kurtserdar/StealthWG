import SwiftUI

/// Lists all profiles: tap to switch the active profile, swipe to delete, + to add.
struct ProfilesListView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                if tunnelManager.profiles.isEmpty {
                    Text("No profiles yet. Tap + to add one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tunnelManager.profiles) { p in
                        NavigationLink {
                            ProfileDetailView(profile: p).environmentObject(tunnelManager)
                        } label: {
                            row(p)
                        }
                    }
                    .onDelete { indexSet in
                        let ids = indexSet.map { tunnelManager.profiles[$0].id }
                        Task { for id in ids { await tunnelManager.deleteProfile(id: id) } }
                    }
                }
            }
            .navigationTitle("Profiles")
            .inlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddProfileView(onComplete: { showAdd = false }).environmentObject(tunnelManager)
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }

    private func row(_ p: TunnelProfile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if p.id == tunnelManager.selectedID {
                        Image(systemName: "checkmark").font(.caption2).foregroundStyle(Theme.accent)
                    }
                    Text(p.name).font(.system(.body, design: .rounded).weight(.medium))
                }
                Text(p.profile.endpoints.first ?? "—")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            if tunnelManager.connectedID == p.id {
                Text("CONNECTED")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.18), in: Capsule())
                    .foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }
}
