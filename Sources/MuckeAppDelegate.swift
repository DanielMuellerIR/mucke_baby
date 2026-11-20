import AppKit
import AppIntents

/// Registriert Kurzbefehle und startet bei Bedarf den isolierten Screenshotlauf.
final class MuckeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        try? TimeshiftSegments.cleanupAbandoned(root: TimeshiftSegments.defaultRoot)
        RadioShortcuts.updateAppShortcutParameters()
        ScreenshotDebug.runIfRequested()
    }
    func applicationWillTerminate(_ notification: Notification) {
        ScreenshotDebug.restorePreferences()
    }
}
