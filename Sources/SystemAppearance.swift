import SwiftUI
import AppKit
import Combine

/// Liefert den aktuellen System-ColorScheme (Hell/Dunkel) und aktualisiert sich live,
/// wenn der Nutzer die Systemeinstellung umstellt. Wird gebraucht, damit das `schlicht`-
/// Theme dem System folgen kann, OHNE `preferredColorScheme(nil)` zu verwenden — denn nil
/// revertet nach einem zuvor erzwungenen .dark/.light nicht zuverlässig.
@MainActor
final class SystemAppearance: ObservableObject {
    @Published var scheme: ColorScheme = SystemAppearance.current()
    private var observer: AnyCancellable?

    init() {
        // macOS feuert diese (undokumentierte, aber stabile) Distributed-Notification beim
        // Hell/Dunkel-Wechsel. Danach den Default neu lesen.
        observer = DistributedNotificationCenter.default().observeOnMain(
            Notification.Name("AppleInterfaceThemeChangedNotification")
        ) { [weak self] in
            self?.scheme = SystemAppearance.current()
        }
    }

    /// Aktueller System-Scheme: `AppleInterfaceStyle == "Dark"` → dunkel, sonst hell.
    static func current() -> ColorScheme {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
    }
}
