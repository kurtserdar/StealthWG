import SwiftUI

@main
struct StealthWGMacApp: App {
    @StateObject private var tunnelManager = TunnelManager()

    var body: some Scene {
        MenuBarExtra("StealthWG", systemImage: "shield.lefthalf.filled") {
            MacMenuView()
                .environmentObject(tunnelManager)
                .task { await tunnelManager.load() }
        }
        .menuBarExtraStyle(.window)

        Window("StealthWG", id: "manage") {
            ManageWindow()
                .environmentObject(tunnelManager)
                .frame(minWidth: 420, minHeight: 480)
                .preferredColorScheme(.dark)
        }
    }
}

/// Management window: empty state or profile detail, both reusing shared views.
private struct ManageWindow: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @State private var showAdd = false

    var body: some View {
        Group {
            if tunnelManager.hasProfile {
                ProfileDetailView().environmentObject(tunnelManager)
            } else {
                VStack(spacing: 16) {
                    Image("MacGhost").resizable().scaledToFit().frame(width: 72, height: 72)
                    Text("Add a profile to get started.").foregroundStyle(.secondary)
                    Button("Add profile") { showAdd = true }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showAdd) {
            AddProfileView(onComplete: { showAdd = false }).environmentObject(tunnelManager)
        }
    }
}
