import SwiftUI
import Combine
import Sparkle

// Selbst-Update über Sparkle (Release-Ablauf: docs/sparkle-release.md).
//
// Sicherheitsmodell — zwei unabhängige Signaturen, beide Pflicht:
//  1. Apple Developer ID + Notarisierung für App und DMG (Gatekeeper).
//  2. Sparkle-Ed25519-Signatur für Update-Archiv und Feed (SUPublicEDKey in der
//     Info.plist; der private Gegenpart liegt NIE im Repo).
// Sparkle prüft automatisch auf Updates (SUEnableAutomaticChecks), installiert
// aber erst nach Zustimmung (SUAllowsAutomaticUpdates=false in der Info.plist).

/// Hält den EINEN langlebigen Sparkle-Updater der App und macht den Zustand
/// „darf gerade suchen?" für SwiftUI beobachtbar (Menüpunkt-Enable/Disable).
/// Mehr als eine Controller-Instanz darf es nicht geben — deshalb lebt er als
/// @StateObject im App-Struct und wird nur dort erzeugt.
@MainActor
final class UpdaterViewModel: ObservableObject {
    /// false z. B. während einer bereits laufenden Suche oder Installation.
    @Published var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    init() {
        // Headless-Screenshot-Läufe (MUCKE_SHOTS) bleiben hermetisch: kein
        // Netz-Check, kein Update-Dialog, der in die Theme-Fotos grätscht.
        let screenshotRun = ProcessInfo.processInfo.environment["MUCKE_SHOTS"] != nil
        controller = SPUStandardUpdaterController(
            startingUpdater: !screenshotRun,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Manuelle Suche (Menüpunkt „Nach Updates suchen …").
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
