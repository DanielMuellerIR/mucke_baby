import AppKit
import ApplicationServices
import CoreGraphics

// Nur im exklusiven nativen Prüfblock eines isolierten Testkontos.
let arguments = CommandLine.arguments
guard (2...3).contains(arguments.count), let pid = Int32(arguments[1]),
      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
      CGPreflightPostEventAccess() else {
    fputs("Eigene Vordergrund-App oder bestehende Event-Freigabe fehlt\n", stderr)
    exit(1)
}

if arguments.count == 3 {
    guard arguments[2] == "--drag-timeshift", AXIsProcessTrusted(), dragTimeshift(in: pid) else {
        fputs("Der Reglerknopf im eigenen Miniplayer konnte nicht sicher gezogen werden\n", stderr)
        exit(2)
    }
    exit(0)
}

for state in [0xA, 0xB] {
    let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)), timestamp: 0,
        windowNumber: 0, context: nil, subtype: 8, data1: (16 << 16) | (state << 8), data2: -1)
    event?.cgEvent?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
}

private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}

private func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

private func timeshiftSlider(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 24 else { return nil }
    if attribute(element, kAXIdentifierAttribute) as? String == "timeshift-position" { return element }
    for child in children(element) {
        if let slider = timeshiftSlider(in: child, depth: depth + 1) { return slider }
    }
    return nil
}

private func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
          let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &extent), extent.width > 0, extent.height > 0 else { return nil }
    return CGRect(origin: point, size: extent)
}

private func dragTimeshift(in pid: pid_t) -> Bool {
    let application = AXUIElementCreateApplication(pid)
    guard let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement],
          let mini = windows.first(where: { attribute($0, kAXIdentifierAttribute) as? String == "MuckeBabyMini" }),
          let slider = timeshiftSlider(in: mini), let track = frame(slider),
          let thumb = children(slider).first(where: { attribute($0, kAXRoleAttribute) as? String == kAXValueIndicatorRole }),
          let knob = frame(thumb) else { return false }
    let start = CGPoint(x: knob.midX, y: knob.midY)
    let end = CGPoint(x: track.minX + 0.2 * track.width, y: start.y)
    var hit: AXUIElement?
    var hitPID: pid_t = 0
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(start.x), Float(start.y), &hit) == .success,
          let hit, AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid,
          let window = attribute(hit, kAXWindowAttribute), CFEqual(window, mini),
          CFEqual(hit, thumb) || CFEqual(hit, slider),
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          let source = CGEventSource(stateID: .privateState) else { return false }

    func send(_ type: CGEventType, to point: CGPoint) -> Bool {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        else { return false }
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        return true
    }
    guard send(.leftMouseDown, to: start) else { return false }
    var dragged = true
    for step in 1...12 {
        let x = start.x + (end.x - start.x) * CGFloat(step) / 12
        if !send(.leftMouseDragged, to: CGPoint(x: x, y: start.y)) {
            dragged = false
            break
        }
    }
    return send(.leftMouseUp, to: end) && dragged
}
