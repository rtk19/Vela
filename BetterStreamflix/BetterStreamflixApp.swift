import SwiftUI

@main
struct BetterStreamflixApp: App {
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(environment.library)
                .preferredColorScheme(.dark)
        }
    }
}
