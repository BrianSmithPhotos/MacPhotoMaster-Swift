import SwiftUI

/// Placeholder entry point for the iPadOS target — proves out the `MacPhotoMasterCore` target
/// split (Services/Models shared with the macOS app) builds and runs on iPadOS. The actual iPad UI
/// is a separate follow-up; this just needs to launch.
@main
struct MacPhotoMasterPadApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
