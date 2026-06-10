import AppKit

// Menu bar-only app — pure AppKit entry point.
// NSStatusItem and NSPopover are managed by AppDelegate.

@MainActor
@main
struct Main {
    static func main() {
        // Enforce single instance — if another copy is already running, activate it and exit.
        guard let bundleID = Bundle.main.bundleIdentifier else {
            assertionFailure("Missing bundle identifier")
            return
        }
        // Skip the single-instance check under XCTest — the test host must keep
        // running even when the installed app is already in the menu bar.
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if !isTesting, running.count > 1 {
            // Activate the other instance (the one that isn't us)
            let me = ProcessInfo.processInfo.processIdentifier
            if let other = running.first(where: { $0.processIdentifier != me }) {
                other.activate()
            }
            exit(0)
        }

        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
