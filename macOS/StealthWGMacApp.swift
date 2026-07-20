import SwiftUI

@main
struct StealthWGMacApp: App {
    @StateObject private var tunnelManager = TunnelManager()
    @StateObject private var systemExtension = SystemExtensionManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        MenuBarExtra("StealthWG", systemImage: "shield.lefthalf.filled") {
            MacMenuView()
                .environmentObject(tunnelManager)
                .environmentObject(systemExtension)
                .task { await tunnelManager.load() }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { Task { await tunnelManager.load() } }
                }
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

/// Management window: the profiles list (add / switch / edit / delete).
private struct ManageWindow: View {
    @EnvironmentObject private var tunnelManager: TunnelManager

    var body: some View {
        ProfilesListView().environmentObject(tunnelManager)
    }
}
