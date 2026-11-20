import SwiftUI

// Globaler UI-Schriftfaktor im Environment (1.0 = normal). Wird für die App-Fenster und die Menüleiste
// gesetzt; alle skalierten Texte multiplizieren ihre Basisgroesse damit.
private struct FontScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var uiFontScale: CGFloat {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

extension View {
    // Ersatz fuer `.font(.<style>)`, der den uiFontScale beruecksichtigt. macOS
    // ignoriert dynamicTypeSize -> wir setzen explizite `.system(size:)`-Groessen.
    func scaledFont(_ style: Font.TextStyle = .body, weight: Font.Weight? = nil) -> some View {
        modifier(ScaledFontModifier(style: style, weight: weight))
    }
}

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.uiFontScale) private var scale
    let style: Font.TextStyle
    let weight: Font.Weight?

    func body(content: Content) -> some View {
        content.font(.system(size: TypographyMetrics.baseSize(style) * scale,
                             weight: weight ?? TypographyMetrics.defaultWeight(style)))
    }
}

// Basis-Punktgroessen der macOS-Textstile (Naeherung), Single Source.
enum TypographyMetrics {
    // Zoom-Stufe (-3 … +5) auf einen Skalierungsfaktor abbilden (~13 % je Stufe).
    static func scale(_ zoom: Int) -> CGFloat {
        max(0.7, min(1.8, 1 + CGFloat(zoom) * 0.13))
    }

    static func baseSize(_ s: Font.TextStyle) -> CGFloat {
        switch s {
        case .largeTitle: return 26
        case .title:      return 22
        case .title2:     return 17
        case .title3:     return 15
        case .headline:   return 13
        case .body:       return 13
        case .callout:    return 12
        case .subheadline: return 11
        case .footnote:   return 10
        case .caption:    return 11
        case .caption2:   return 10
        @unknown default: return 13
        }
    }
    static func defaultWeight(_ s: Font.TextStyle) -> Font.Weight {
        s == .headline ? .semibold : .regular
    }
}

// Kleiner Font-Helfer: routet einen festen Text durch den Theme-Font-Resolver
// (`theme.font(slot, size:weight:)`). Fuer schlicht liefert der Resolver
// `.system(size:weight:)` — bei gleicher Groesse also identisch zum frueheren
// `scaledFont`. Console-Themes bekommen ihre eigene Schriftfamilie (Serif/Mono/…).
// `size` schon mit dem uiFontScale multipliziert uebergeben.
extension View {
    func themedFont(_ theme: Theme, _ slot: FontSlot, size: CGFloat,
                    weight: Font.Weight = .regular) -> some View {
        self.font(theme.font(slot, size: size, weight: weight))
    }
}
