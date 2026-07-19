import SwiftUI
import MacPhotoMasterCore

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

        // No `.app` bundle means no Info.plist `CFBundleIconFile` either, so the Dock/Cmd+Tab icon
        // has to be set programmatically instead. Going through `applicationIconImage` also skips
        // the automatic squircle-corner masking a bundled `.icns`/asset catalog icon would get, so
        // `Self.roundedIcon` applies that mask by hand — otherwise the source PNG (a plain square
        // photo, no built-in corner treatment) shows up as a hard-edged square in the Dock, unlike
        // every other app there.
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
            let icon = NSImage(contentsOf: iconURL)
        {
            NSApp.applicationIconImage = Self.roundedIcon(from: icon)
        }
    }

    /// Clips `image` to macOS's app-icon proportions (per Apple's Big Sur+ icon grid: the visible
    /// rounded shape is inset to ~824/1024 of the canvas, centered, with a ~183/824 corner radius)
    /// so a plain full-bleed square source image reads as a normal Dock icon rather than looking
    /// oversized next to every other app's icon, which already has this margin baked in.
    private static func roundedIcon(from image: NSImage) -> NSImage {
        let canvasSize = image.size
        let insetSize = NSSize(width: canvasSize.width * (824.0 / 1024.0), height: canvasSize.height * (824.0 / 1024.0))
        let origin = NSPoint(x: (canvasSize.width - insetSize.width) / 2, y: (canvasSize.height - insetSize.height) / 2)
        let cornerRadius = insetSize.width * (183.0 / 824.0)

        let rounded = NSImage(size: canvasSize)
        rounded.lockFocus()
        let path = NSBezierPath(
            roundedRect: NSRect(origin: origin, size: insetSize), xRadius: cornerRadius, yRadius: cornerRadius)
        path.addClip()
        image.draw(in: NSRect(origin: origin, size: insetSize))
        rounded.unlockFocus()
        return rounded
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
