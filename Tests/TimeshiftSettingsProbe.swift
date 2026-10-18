import Foundation
import SwiftUI
import AppKit

@main @MainActor final class TimeshiftSettingsProbe: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var player: RadioPlayer!
    private var root: URL!
    private var streamURL: URL!
    static func main() {
        let delegate = TimeshiftSettingsProbe()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        root = URL(fileURLWithPath: CommandLine.arguments[1])
        streamURL = URL(string: CommandLine.arguments[2])!
        try? Data(String(getpid()).utf8).write(to: root.appendingPathComponent("app.pid"))
        let preferences = UserDefaults(suiteName: "TimeshiftSettingsProbe")!
        preferences.removePersistentDomain(forName: "TimeshiftSettingsProbe")
        player = RadioPlayer(recorder: Recorder(directory: root.appendingPathComponent("recordings")), preferences: preferences,
            history: SongHistory(directory: root.appendingPathComponent("history")), timeshiftRoot: root.appendingPathComponent("buffers"))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Mucke, Baby! — Zeitversatz-Einstellungen"
        install(theme: .schlicht, width: 660, dark: false)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        Task { do { try await run(); finish(nil) } catch { finish(error) } }
    }
    private func install(theme: ThemeID, width: Double, dark: Bool) {
        let view = VStack(alignment: .leading, spacing: 14) {
            Text("Einstellungen").font(.headline)
            Form { TimeshiftSettingsView() }.formStyle(.grouped)
        }.padding(20).environmentObject(player).environment(\.theme, Theme.theme(raw: theme.rawValue))
            .preferredColorScheme(dark ? .dark : .light)
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(NSSize(width: width, height: 480))
    }
    private func shot(_ name: String) throws {
        let view = (name == "confirmation" ? window.attachedSheet?.contentView : nil) ?? window.contentView!
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
    }
    private func run() async throws {
        for theme in ThemeID.allCases {
            for width in [940.0, 660.0] {
                for dark in [false, true] {
                    install(theme: theme, width: width, dark: dark)
                    try await Task.sleep(nanoseconds: 150_000_000)
                    try shot("\(theme.rawValue)-\(Int(width))-\(dark ? "dark" : "light")")
                }
            }
        }
        precondition(!player.timeshiftRequested && !player.recordingRequested)
        install(theme: .schlicht, width: 660, dark: false)
        try Data("ready".utf8).write(to: root.appendingPathComponent("ready.txt"))
        try await wait { FileManager.default.fileExists(atPath: self.root.appendingPathComponent("ui-enabled.txt").path) }
        precondition(player.timeshiftRequested)
        player.setVolume(0); player.setRecordingRequested(true)
        player.play(Station(name: "Fixture A", url: streamURL.absoluteString))
        try await wait { self.bufferDirectories().count == 1 && self.player.isPlaying }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let first = bufferDirectories()[0]
        precondition(!player.timeshiftStatus.contains("gestoppt"))
        try shot("buffering")
        try Data("buffering".utf8).write(to: root.appendingPathComponent("buffering.txt"))
        try await wait { !self.player.timeshiftRequested }
        precondition(!FileManager.default.fileExists(atPath: first.path))
        precondition(player.recordingRequested && player.isPlaying)
        try shot("disabled")
        try Data("disabled".utf8).write(to: root.appendingPathComponent("disabled.txt"))
        try await wait { self.player.timeshiftRequested }
        try await wait { self.bufferDirectories().count == 1 }
        let second = bufferDirectories()[0]
        player.play(Station(name: "Fixture B", url: streamURL.absoluteString))
        try await wait { !FileManager.default.fileExists(atPath: second.path) && self.bufferDirectories().count == 1 && self.player.isPlaying }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try shot("changed-station")
        try Data("passed".utf8).write(to: root.appendingPathComponent("result.txt"))
    }
    private func bufferDirectories() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("buffers"), includingPropertiesForKeys: nil))?.filter { UUID(uuidString: $0.lastPathComponent) != nil } ?? []
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("shot-request.txt").path) {
                try shot("confirmation"); try FileManager.default.removeItem(at: root.appendingPathComponent("shot-request.txt"))
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "TimeshiftSettingsProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timeout"])
    }
    private func finish(_ error: Error?) {
        if let error { try? Data(String(describing: error).utf8).write(to: root.appendingPathComponent("failure.txt")) }
        window.orderOut(nil); NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) { player?.stop(); player?.recorder.flush() }
}
