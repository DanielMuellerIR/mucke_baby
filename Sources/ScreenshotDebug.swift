// ScreenshotDebug.swift — Headless-Theme-Screenshots fuer die visuelle Verifikation.
//
// Wird NUR aktiv, wenn die Umgebungsvariable `MUCKE_SHOTS=<zielordner>` gesetzt ist.
// Dann schaltet die App nach dem Start automatisch durch alle Themes und fotografiert
// jeweils ihr eigenes Fenster in eine PNG — OHNE Screen-Recording-Rechte, weil ein
// Programm seine eigene View jederzeit in ein Bitmap zeichnen darf (`cacheDisplay`).
// Danach beendet sie sich selbst. Im Normalbetrieb (ohne die Variable) passiert nichts.

import SwiftUI
import AppKit

/// App-Delegate nur fuer den Screenshot-Trigger. Im Normalbetrieb ein No-Op.
final class MuckeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ScreenshotDebug.runIfRequested()
    }
}

enum ScreenshotDebug {
    /// Plant — falls `MUCKE_SHOTS` gesetzt — den Durchlauf durch alle Themes.
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["MUCKE_SHOTS"], !dir.isEmpty else { return }
        let outDir = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let ids = ThemeID.allCases
        let step = 1.6          // Sekunden pro Theme (Umschalten + Relayout + Schuss)
        let startDelay = 4.0    // warten, bis Fenster da UND Senderliste async geladen ist

        // Fenstergroesse NUR auf Wunsch via Env MUCKE_SHOT_W aendern (zum Pruefen mehrerer
        // Breiten). Ohne die Variable bleibt die natuerliche Startgroesse — das vermeidet
        // einen Repaint-Artefakt der classic-NavigationStack-List nach programmatischem Resize.
        if let wStr = ProcessInfo.processInfo.environment["MUCKE_SHOT_W"], let shotW = Double(wStr) {
            let shotH = max(620, shotW * 0.60)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let win = NSApp.windows.first(where: { ($0.contentView?.bounds.height ?? 0) > 300 }) {
                    win.setContentSize(NSSize(width: shotW, height: shotH))
                    win.center()
                }
            }
        }

        for (i, id) in ids.enumerated() {
            let base = startDelay + Double(i) * step
            // 1) Theme umschalten (das @AppStorage in der App reagiert auf denselben Key).
            DispatchQueue.main.asyncAfter(deadline: .now() + base) {
                UserDefaults.standard.set(id.rawValue, forKey: "selectedTheme")
            }
            // 2) nach kurzem Relayout das Fenster fotografieren.
            DispatchQueue.main.asyncAfter(deadline: .now() + base + 1.0) {
                capture(to: outDir.appendingPathComponent("\(id.rawValue).png"))
            }
        }
        // 3) am Ende die App schliessen.
        DispatchQueue.main.asyncAfter(deadline: .now() + startDelay + Double(ids.count) * step + 0.8) {
            NSApp.terminate(nil)
        }
    }

    /// Zeichnet das Inhaltsfenster (SwiftUI-Content) in eine PNG.
    static func capture(to url: URL) {
        // Groesstes sichtbares Fenster = Hauptfenster (nicht das MenuBar-Popup).
        guard let win = NSApp.windows
                .filter({ $0.isVisible && ($0.contentView?.bounds.height ?? 0) > 300 })
                .max(by: { ($0.contentView?.bounds.height ?? 0) < ($1.contentView?.bounds.height ?? 0) }),
              let view = win.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("MUCKE_SHOTS: kein Fenster fuer \(url.lastPathComponent)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            NSLog("MUCKE_SHOTS: \(url.lastPathComponent) (\(Int(view.bounds.width))x\(Int(view.bounds.height)))")
        }
    }
}
