import SwiftUI

@main
struct StealthWGApp: App {
    @StateObject private var tunnelManager = TunnelManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tunnelManager)
                .preferredColorScheme(.dark)
                .task { await tunnelManager.load() }
                .onChange(of: scenePhase) { phase in
                    // Re-sync (and re-publish the widget snapshot) when the app
                    // returns to the foreground.
                    if phase == .active { Task { await tunnelManager.load() } }
                }
        }
    }
}
