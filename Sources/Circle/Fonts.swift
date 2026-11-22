import AppKit
import SwiftUI

extension Notification.Name {
    static let circleSettingsChanged = Notification.Name("circleSettingsChanged")
}

/// One place that turns settings.json "font_family" / "font_weight" into fonts.
/// Empty family = SF Mono (the system monospaced face). "system" = SF Pro.
/// Any installed family or PostScript name works: "JetBrains Mono", "Inter", "IBMPlexMono-Light".
@MainActor
enum Fonts {
    private static var cache: [String: NSFont] = [:]
    private static var cacheKey = ""

    static let weights = ["ultralight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy"]

    static func ns(size: CGFloat, weight: String? = nil) -> NSFont {
        let s = Settings.shared
        let family = s.fontFamily.trimmingCharacters(in: .whitespaces)
        let base = s.fontWeight
        let w = weight ?? base
        let stamp = "\(family)|\(base)"
        if stamp != cacheKey { cache.removeAll(); cacheKey = stamp }
        let key = "\(w)|\(size)"
        if let f = cache[key] { return f }
        let f = make(family: family, weight: w, size: size)
        cache[key] = f
        return f
    }

    /// A heavier cut of the user's font for headings and **bold**: two steps above their base weight.
    static func bolder(size: CGFloat) -> NSFont {
        let i = weights.firstIndex(of: Settings.shared.fontWeight) ?? 3
        return ns(size: size, weight: weights[min(weights.count - 1, max(i + 2, 5))])
    }

    static func swiftUI(size: CGFloat, weight: String? = nil) -> Font { Font(ns(size: size, weight: weight) as CTFont) }

    /// True when the family resolves to an installed font (used to warn about typos).
    static func exists(_ family: String) -> Bool {
        ["", "system", "sf pro", "sf mono", "mono", "monospace"].contains(family.lowercased()) || NSFontManager.shared.availableMembers(ofFontFamily: family) != nil || NSFont(name: family, size: 12) != nil
    }

    private static func make(family: String, weight: String, size: CGFloat) -> NSFont {
        let f = family.lowercased()
        if f == "system" || f == "sf pro" { return NSFont.systemFont(ofSize: size, weight: systemWeight(weight)) }
        if f.isEmpty || f == "sf mono" || f == "mono" || f == "monospace" { return NSFont.monospacedSystemFont(ofSize: size, weight: systemWeight(weight)) }
        if !family.isEmpty {
            if let members = NSFontManager.shared.availableMembers(ofFontFamily: family), !members.isEmpty {
                // Pick the upright member whose weight is closest to the one asked for.
                let want = managerWeight(weight)
                let upright = members.filter { m in
                    let traits = NSFontTraitMask(rawValue: (m[3] as? NSNumber)?.uintValue ?? 0)
                    return !traits.contains(.italicFontMask)
                }
                let pick = (upright.isEmpty ? members : upright).min { a, b in
                    abs(((a[2] as? NSNumber)?.intValue ?? 5) - want) < abs(((b[2] as? NSNumber)?.intValue ?? 5) - want)
                }
                if let name = pick?[0] as? String, let f = NSFont(name: name, size: size) { return f }
            }
            if let f = NSFont(name: family, size: size) { return f }   // a PostScript name
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: systemWeight(weight))
    }

    private static func systemWeight(_ w: String) -> NSFont.Weight {
        switch w {
        case "ultralight": return .ultraLight
        case "thin": return .thin
        case "light": return .light
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        default: return .regular
        }
    }

    /// NSFontManager's 0–15 weight scale.
    private static func managerWeight(_ w: String) -> Int {
        ["ultralight": 2, "thin": 3, "light": 4, "regular": 5, "medium": 6, "semibold": 8, "bold": 9, "heavy": 11][w] ?? 5
    }
}
