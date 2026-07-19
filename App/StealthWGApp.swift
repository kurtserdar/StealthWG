import SwiftUI

@main
struct StealthWGApp: App {
    @StateObject private var tunnelManager = TunnelManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tunnelManager)
                .preferredColorScheme(.dark)
                .task { await tunnelManager.load() }
        }
    }
}
