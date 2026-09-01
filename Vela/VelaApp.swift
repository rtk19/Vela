import SwiftUI
import UIKit

enum PlayerOrientationPreference: String, CaseIterable, Identifiable {
    case autoRotate
    case landscapeOnly

    var id: Self { self }

    var name: String {
        switch self {
        case .autoRotate: "Auto-Rotate"
        case .landscapeOnly: "Landscape Only"
        }
    }

    var supportedOrientations: UIInterfaceOrientationMask {
        switch self {
        case .autoRotate: .allButUpsideDown
        case .landscapeOnly: [.landscapeLeft, .landscapeRight]
        }
    }
}

@MainActor
final class AppOrientationController {
    static let shared = AppOrientationController()

    private(set) var supportedOrientations: UIInterfaceOrientationMask = .portrait

    private init() {}

    func beginPlayback(using preference: PlayerOrientationPreference) {
        updateSupportedOrientations(
            preference.supportedOrientations,
            requestsGeometryUpdate: preference == .landscapeOnly
        )
    }

    func endPlayback() {
        updateSupportedOrientations(.portrait, requestsGeometryUpdate: true)
    }

    private func updateSupportedOrientations(
        _ orientations: UIInterfaceOrientationMask,
        requestsGeometryUpdate: Bool
    ) {
        supportedOrientations = orientations

        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            guard requestsGeometryUpdate else { continue }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppOrientationController.shared.supportedOrientations
    }
}

@main
struct VelaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(environment.library)
                .environmentObject(environment.sourceLookup)
                .preferredColorScheme(.dark)
        }
    }
}
