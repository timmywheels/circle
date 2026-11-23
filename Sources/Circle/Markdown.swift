import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// A [[wikilink]] name or a URL; clicking it follows the link.
    static let circleLink = NSAttributedString.Key("circleLink")
}

/// Markdown styled in place, Zed style: the text stays plain (markers dimmed, still editable),
/// it just gets headings, hanging-indent lists, bold/italic/code and clickable links.
/// Runs on every edit of the notes' text storage; notes are small, so a full pass is cheap.
@MainActor
final class MarkdownStyler: NSObject, NSTextStorageDelegate {
    static let shared = MarkdownStyler()

    var onLink: ((String) -> Void)?
    private var views: [ObjectIdentifier: WeakView] = [:]
    private var styling = false
    private var monitor: Any?

    private final class WeakView { weak var tv: NSTextView?; init(_ tv: NSTextView) { self.tv = tv } }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: .circleSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for w in self.views.values { if let ts = w.tv?.textStorage { self.restyle(ts) } }
            }
        }
    }

    func attach(_ tv: NSTextView) {
        tv.insertionPointColor = .labelColor
        guard let ts = tv.textStorage else { return }
        let key = ObjectIdentifier(tv)
        if views[key]?.tv == nil {
            views = views.filter { $0.value.tv != nil }
            views[key] = WeakView(tv)
            if ts.delegate == nil || ts.delegate === self { ts.delegate = self }
            else {
                NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: ts, queue: nil) { [weak self] n in
                    guard let ts = n.object as? NSTextStorage else { return }
                    MainActor.assumeIsolated { self?.restyle(ts) }
                }
            }
            installMonitor()
        }
        restyle(ts)
    }

    nonisolated func textStorage(_ ts: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength: Int) {
        MainActor.assumeIsolated { style(ts) }
    }

    /// Outside an editing pass: batch so the layout invalidates once.
    private func restyle(_ ts: NSTextStorage) {
        guard !styling else { return }
        ts.beginEditing(); style(ts); styling = true; ts.endEditing(); styling = false
    }

    // MARK: styling

    private let label = NSColor.labelColor
    private var body: NSColor { NSColor.ink(0.72) }
    private var dim: NSColor { NSColor.ink(0.38) }
    private var faint: NSColor { NSColor.ink(0.22) }
    private var codeBG: NSColor { NSColor.ink(0.07) }

    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})\s+"#)
    private static let list = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d{1,3}[.)])\s+(\[[ xX]\]\s+)?"#)
    private static let quote = try! NSRegularExpression(pattern: #"^>\s?"#)
    private static let code = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let bold = try! NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#)
    private static let italic = try! NSRegularExpression(pattern: #"(?<![*\w])[*_]([^*_\n]+)[*_](?![*\w])"#)
    private static let strike = try! NSRegularExpression(pattern: #"~~([^~\n]+)~~"#)
    private static let wiki = try! NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#)
    private static let url = try! NSRegularExpression(pattern: #"https?://[^\s)>\]]+"#)

    private func style(_ ts: NSTextStorage) {
        guard !styling else { return }
        styling = true
        defer { styling = false }
        let s = ts.string as NSString
        let full = NSRange(location: 0, length: s.length)
        let size = CGFloat(Settings.shared.fontSize)
        let base = Fonts.ns(size: size)
        // Hanging indents measure the actual marker text, so proportional fonts line up too.
        func width(_ str: String) -> CGFloat { (str as NSString).size(withAttributes: [.font: base]).width }
        ts.setAttributes([.font: base, .foregroundColor: body, .paragraphStyle: para(0)], range: full)
        guard full.length > 0 else { return }

        var inFence = false
        s.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
            let line = s.substring(with: r)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                ts.addAttribute(.foregroundColor, value: self.faint, range: r)
                return
            }
            if inFence {
                ts.addAttributes([.foregroundColor: self.dim, .backgroundColor: self.codeBG], range: r)
                return
            }
            let lr = NSRange(location: 0, length: (line as NSString).length)
            if let m = Self.heading.firstMatch(in: line, range: lr) {
                let level = m.range(at: 1).length
                let f = Fonts.bolder(size: size + CGFloat(max(0, 4 - level)))
                ts.addAttributes([.font: f, .foregroundColor: self.label], range: r)
                ts.addAttribute(.foregroundColor, value: self.faint, range: NSRange(location: r.location, length: m.range.length))
                let p = self.para(0); p.paragraphSpacingBefore = level <= 2 ? 6 : 3
                ts.addAttribute(.paragraphStyle, value: p, range: r)
            } else if let m = Self.list.firstMatch(in: line, range: lr) {
                // Wrapped lines hang under the item's text, not under the marker.
                ts.addAttribute(.paragraphStyle, value: self.para(width((line as NSString).substring(with: m.range))), range: r)
                let marker = m.range(at: 2)
                ts.addAttribute(.foregroundColor, value: self.dim, range: NSRange(location: r.location + marker.location, length: marker.length))
                let box = m.range(at: 3)
                if box.location != NSNotFound {
                    ts.addAttribute(.foregroundColor, value: self.dim, range: NSRange(location: r.location + box.location, length: box.length))
                    let checked = (line as NSString).substring(with: box).lowercased().contains("x")
                    if checked {
                        let rest = NSRange(location: r.location + m.range.length, length: r.length - m.range.length)
                        ts.addAttributes([.foregroundColor: self.faint, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: rest)
                    }
                }
            } else if let m = Self.quote.firstMatch(in: line, range: lr) {
                ts.addAttributes([.foregroundColor: self.dim, .paragraphStyle: self.para(width("> "))], range: r)
                ts.addAttribute(.foregroundColor, value: self.faint, range: NSRange(location: r.location, length: m.range.length))
            }
            self.inline(ts, line: line, at: r.location)
        }
    }

    private func inline(_ ts: NSTextStorage, line: String, at offset: Int) {
        let lr = NSRange(location: 0, length: (line as NSString).length)
        func abs(_ r: NSRange) -> NSRange { NSRange(location: r.location + offset, length: r.length) }
        func markers(_ m: NSTextCheckingResult) {
            let whole = m.range, inner = m.range(at: 1)
            ts.addAttribute(.foregroundColor, value: faint, range: abs(NSRange(location: whole.location, length: inner.location - whole.location)))
            let end = inner.location + inner.length
            ts.addAttribute(.foregroundColor, value: faint, range: abs(NSRange(location: end, length: whole.location + whole.length - end)))
        }
        for m in Self.bold.matches(in: line, range: lr) {
            reweight(ts, abs(m.range(at: 1)), bold: true); markers(m)
        }
        for m in Self.italic.matches(in: line, range: lr) {
            reweight(ts, abs(m.range(at: 1)), bold: false); markers(m)
        }
        for m in Self.strike.matches(in: line, range: lr) {
            ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: abs(m.range(at: 1))); markers(m)
        }
        for m in Self.code.matches(in: line, range: lr) {
            ts.addAttribute(.backgroundColor, value: codeBG, range: abs(m.range))
            ts.addAttribute(.foregroundColor, value: label, range: abs(m.range(at: 1))); markers(m)
        }
        for m in Self.wiki.matches(in: line, range: lr) {
            let name = (line as NSString).substring(with: m.range(at: 1))
            ts.addAttributes([.foregroundColor: label, .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .underlineColor: NSColor.ink(0.3), .circleLink: "wiki:" + name,
                              .cursor: NSCursor.pointingHand], range: abs(m.range(at: 1)))
            markers(m)
        }
        for m in Self.url.matches(in: line, range: lr) {
            let u = (line as NSString).substring(with: m.range)
            ts.addAttributes([.foregroundColor: label, .underlineColor: NSColor.ink(0.3), .circleLink: u,
                              .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand], range: abs(m.range))
        }
    }

    private func reweight(_ ts: NSTextStorage, _ r: NSRange, bold: Bool) {
        ts.enumerateAttribute(.font, in: r) { v, sub, _ in
            guard let f = v as? NSFont else { return }
            var nf: NSFont
            if bold { nf = Fonts.bolder(size: f.pointSize) }
            else {
                let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic))
                nf = NSFont(descriptor: d, size: f.pointSize) ?? f
            }
            ts.addAttribute(.font, value: nf, range: sub)
        }
        if bold { ts.addAttribute(.foregroundColor, value: label, range: r) }
    }

    private func para(_ indent: CGFloat) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        p.headIndent = indent
        return p
    }

    // MARK: links

    /// Plain click on a link follows it (instead of moving the caret); drags and selections are untouched.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, e.clickCount == 1, !e.modifierFlags.contains(.shift) else { return e }
                for w in self.views.values {
                    guard let tv = w.tv, tv.window === e.window, let link = self.link(in: tv, at: e) else { continue }
                    if link.hasPrefix("wiki:") { self.onLink?(String(link.dropFirst(5))) }
                    else if let u = URL(string: link) { NSWorkspace.shared.open(u) }
                    return nil
                }
                return e
            }
        }
    }

    private func link(in tv: NSTextView, at e: NSEvent) -> String? {
        let p = tv.convert(e.locationInWindow, from: nil)
        guard tv.visibleRect.contains(p), let lm = tv.layoutManager, let tc = tv.textContainer, let ts = tv.textStorage,
              ts.length > 0 else { return nil }
        let pt = NSPoint(x: p.x - tv.textContainerOrigin.x, y: p.y - tv.textContainerOrigin.y)
        var frac: CGFloat = 0
        let gi = lm.glyphIndex(for: pt, in: tc, fractionOfDistanceThroughGlyph: &frac)
        guard lm.boundingRect(forGlyphRange: NSRange(location: gi, length: 1), in: tc).contains(pt) else { return nil }
        let ci = lm.characterIndexForGlyph(at: gi)
        guard ci < ts.length else { return nil }
        return ts.attribute(.circleLink, at: ci, effectiveRange: nil) as? String
    }
}

/// Finds the NSTextView behind a sibling SwiftUI TextEditor and hands it to the styler.
struct MarkdownHook: NSViewRepresentable {
    let onLink: (String) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { attach(from: v) }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { attach(from: v) }
    }

    private func attach(from v: NSView) {
        MarkdownStyler.shared.onLink = onLink
        var node: NSView? = v.superview
        for _ in 0..<5 {
            guard let n = node else { return }
            if let tv = Self.find(in: n) { MarkdownStyler.shared.attach(tv); return }
            node = n.superview
        }
    }

    private static func find(in v: NSView) -> NSTextView? {
        // Only the notes editor: never the list buffer (it styles itself) or a field editor.
        if let tv = v as? NSTextView, !(tv is BufferTextView), !tv.isFieldEditor, tv.isEditable, tv.enclosingScrollView != nil { return tv }
        if v is NSScrollView, (v as? NSScrollView)?.documentView is BufferTextView { return nil }
        for s in v.subviews { if let t = find(in: s) { return t } }
        return nil
    }
}
