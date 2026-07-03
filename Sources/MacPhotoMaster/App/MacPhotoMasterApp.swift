import SwiftUI

/// `swift run` execs the built binary directly with no `.app` bundle around it, so LaunchServices
/// never registers this process as a real foreground app — it can still create/show windows and
/// take mouse clicks (window-level hit testing doesn't care), but it never becomes the system
/// "active application", so menu-bar keyboard shortcuts (Cmd+, for Settings, etc.) keep routing to
/// whatever terminal/IDE actually launched it. Explicitly claiming `.regular` activation policy and
/// activating on launch fixes this without needing to package a bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct MacPhotoMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Owned here (rather than by `ContentView`) so the Settings scene below can share the same
    /// instance — the library-root setting it edits has to be visible to the main window's process
    /// actions, not a separate copy.
    @StateObject private var browser = SourceBrowserViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(browser: browser)
        }
        Settings {
            SettingsView(viewModel: browser)
        }
    }
}
