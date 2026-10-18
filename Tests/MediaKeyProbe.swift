import AppKit
import CoreGraphics

// Nur im exklusiven nativen Prüfblock eines isolierten Testkontos.
let arguments = CommandLine.arguments
guard arguments.count == 2, let pid = Int32(arguments[1]),
      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
      CGPreflightPostEventAccess() else {
    fputs("Eigene Vordergrund-App oder bestehende Event-Freigabe fehlt\n", stderr)
    exit(1)
}
for state in [0xA, 0xB] {
    let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)), timestamp: 0,
        windowNumber: 0, context: nil, subtype: 8, data1: (16 << 16) | (state << 8), data2: -1)
    event?.cgEvent?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
}
