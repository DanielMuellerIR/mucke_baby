import Foundation
import CoreGraphics

@main
struct MiniWindowHarness {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func main() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 850)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let external = CGRect(x: -1000, y: 300, width: 420, height: 240)
        check(MiniWindowPlacement.visibleFrame(external, screens: [primary, left]) == external, "Sichtbares Fenster auf negativem Display wird verschoben")
        let unplugged = MiniWindowPlacement.visibleFrame(external, screens: [primary])!
        check(unplugged == CGRect(x: 0, y: 300, width: 420, height: 240), "Entferntes Display lässt Fenster außerhalb zurück")
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let edge = CGRect(x: 1500, y: 980, width: 600, height: 400)
        check(MiniWindowPlacement.visibleFrame(edge, screens: [primary, right]) == CGRect(x: 1500, y: 680, width: 600, height: 400), "Oberer Rand wird nicht auf dem richtigen Display begrenzt")
        check(MiniWindowPlacement.visibleFrame(CGRect(x: -2000, y: -2000, width: 2000, height: 1500), screens: [primary]) == primary, "Übergrößes Fenster bleibt teilweise unsichtbar")
        let invalid = CGRect(x: Double.nan, y: 0, width: 420, height: 240)
        check(MiniWindowPlacement.visibleFrame(invalid, screens: [primary]) == CGRect(x: 1020, y: 610, width: 420, height: 240), "Ungültige gespeicherte Geometrie wird übernommen")
        check(MiniWindowPlacement.visibleFrame(external, screens: []) == nil, "Fehlende Displays führen zu erfundener Geometrie")
        let above = CGRect(x: 0, y: 900, width: 1440, height: 900)
        let topWindow = CGRect(x: 100, y: 1500, width: 420, height: 240)
        check(MiniWindowPlacement.visibleFrame(topWindow, screens: [primary, above]) == topWindow, "Vertikal angeordnetes Display wird falsch behandelt")
        print("MiniWindowHarness: negative/vertikale Displays, entfernte Bildschirme, Übergröße und ungültige Geometrie OK")
    }
}
