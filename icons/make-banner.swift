#!/usr/bin/env swift
// Baut den GitHub-Social-Banner (1280x640): Icon links, Titel/Untertitel/Tagline rechts.
// Nativ via AppKit/CoreGraphics — keine externen Abhaengigkeiten.
//
// Aufruf:
//   swift make-banner.swift [ICON_PNG] [OUT_PNG]
// Defaults: brushed s123 -> social-brushed-s123.png
import AppKit

let args = CommandLine.arguments
// Default = eingecheckter Master (candidates/ ist gitignored).
let iconPath = args.count > 1 ? args[1] : "app-icon-brushed-s123.png"
let outPath  = args.count > 2 ? args[2] : "social-brushed-s123.png"

let W = 1280.0, H = 640.0
let image = NSImage(size: NSSize(width: W, height: H))
image.lockFocus()

// --- Hintergrund: diagonaler dunkler Verlauf (oben-links heller -> unten-rechts fast schwarz)
let bg = NSGradient(colors: [
    NSColor(srgbRed: 0.13, green: 0.14, blue: 0.18, alpha: 1),
    NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1),
])!
bg.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -55)

// --- Icon links, vertikal zentriert
let iconSize = 280.0
let iconX = 70.0
let iconY = (H - iconSize) / 2
if let icon = NSImage(contentsOfFile: iconPath) {
    icon.draw(in: NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize))
}

// --- Textblock rechts
let textX = iconX + iconSize + 70.0   // = 420

func draw(_ s: String, font: NSFont, color: NSColor, topY: CGFloat) {
    // topY = Abstand der Textoberkante von der OBERKANTE des Banners.
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: s, attributes: attrs)
    let lineH = font.ascender - font.descender
    // AppKit-Origin ist unten-links -> Baseline-Punkt von oben her umrechnen.
    let y = H - topY - lineH
    str.draw(at: NSPoint(x: textX, y: y))
}

draw("Mucke, Baby!",
     font: .systemFont(ofSize: 82, weight: .bold),
     color: .white,
     topY: 180)
draw("Webradio-Player für macOS",
     font: .systemFont(ofSize: 36, weight: .regular),
     color: NSColor(srgbRed: 0.80, green: 0.82, blue: 0.86, alpha: 1),
     topY: 300)
draw("Songtitel · Verlauf · Aufnahme & Export",
     font: .systemFont(ofSize: 29, weight: .medium),
     color: NSColor(srgbRed: 0.40, green: 0.62, blue: 0.90, alpha: 1),
     topY: 372)

image.unlockFocus()

// --- als PNG schreiben
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG-Erzeugung fehlgeschlagen\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("geschrieben: \(outPath)")
