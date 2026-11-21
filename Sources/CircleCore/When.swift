import Foundation

/// Parses reminder phrases: "tomorrow 9am", "fri 2pm", "in 30 min", "30m",
/// "every weekday 8:30", "1st every month", "every 2 hours".
/// Repeat rules are stored as "minute:N", "hour:N", "day:N", "week:N", "month:N", "year:N" or "weekdays".
public enum When {
    public struct Parsed: Equatable {
        public let date: Date
        public let rule: String
    }

    private static let units: [(pattern: String, unit: String)] = [
        ("min(?:ute)?s?|m", "minute"), ("h(?:ou)?rs?|hours?|h", "hour"), ("days?|d", "day"),
        ("weeks?|w", "week"), ("months?", "month"), ("years?", "year"),
    ]

    public static func parse(_ raw: String, now: Date = Date(), defaultHour: Int = 9) -> Parsed? {
        var s = " " + raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) + " "
        guard s.trimmingCharacters(in: .whitespaces).count > 0 else { return nil }
        var rule = ""
        let cal = Calendar.current

        func take(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
            let groups = (0..<m.numberOfRanges).map { i -> String in
                guard let r = Range(m.range(at: i), in: s) else { return "" }
                return String(s[r])
            }
            s.replaceSubrange(Range(m.range, in: s)!, with: " ")
            return groups
        }

        // Repeat phrases first, so the date detector only sees the "when".
        for (p, u) in units {
            if let g = take(#"\bevery\s+(\d+)\s*(?:"# + p + #")\b"#), let n = Int(g[1]), n > 0 { rule = "\(u):\(n)"; break }
        }
        if rule.isEmpty {
            if take(#"\b(?:every\s*weekdays?|weekdays)\b"#) != nil { rule = "weekdays" }
            else if take(#"\b(?:daily|every\s*day)\b"#) != nil { rule = "day:1" }
            else if take(#"\b(?:weekly|every\s*week)\b"#) != nil { rule = "week:1" }
            else if take(#"\b(?:monthly|every\s*month)\b"#) != nil { rule = "month:1" }
            else if take(#"\b(?:yearly|annually|every\s*year)\b"#) != nil { rule = "year:1" }
            else if take(#"\bevery\s+(?=(?:mon|tue|wed|thu|fri|sat|sun))"#) != nil { rule = "week:1" }
        }

        // Shorthand offsets: "30m", "in 2h", "in 3 days".
        for (p, u) in units {
            if let g = take(#"^\s*(?:in\s+)?(\d+)\s*(?:"# + p + #")\s*$"#), let n = Int(g[1]) {
                let comp: Calendar.Component = [ "minute": .minute, "hour": .hour, "day": .day, "week": .weekOfYear,
                                                 "month": .month, "year": .year ][u]!
                if let d = cal.date(byAdding: comp, value: n, to: now) { return Parsed(date: d, rule: rule) }
            }
        }

        // Day-of-month like "1st", which the detector doesn't read on its own.
        var dayOfMonth: Int?
        if let g = take(#"\b(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)\b"#), let d = Int(g[1]), (1...31).contains(d) { dayOfMonth = d }

        let rest = s.trimmingCharacters(in: .whitespaces)
        let explicitTime = rest.range(of: #"(\d{1,2}(:\d{2})?\s*(am|pm|a|p)\b)|(\b\d{1,2}:\d{2}\b)|noon|midnight|morning|afternoon|evening|tonight"#,
                                      options: .regularExpression) != nil
        let explicitDay = dayOfMonth != nil || rest.range(of: #"today|tomorrow|tmrw|mon|tue|wed|thu|fri|sat|sun|next|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|\d{1,2}/\d{1,2}"#,
                                                         options: .regularExpression) != nil

        var date: Date?
        if !rest.isEmpty, let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            var text = rest
            for (word, full) in ["tmrw": "tomorrow", "tonight": "today 8pm", "morning": "9am", "evening": "6pm", "afternoon": "2pm"] {
                text = text.replacingOccurrences(of: word, with: full)
            }
            date = det.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.date
        }

        if let dom = dayOfMonth {
            var c = cal.dateComponents([.year, .month], from: now)
            c.day = dom
            let t = date.map { cal.dateComponents([.hour, .minute], from: $0) }
            c.hour = explicitTime ? t?.hour : defaultHour
            c.minute = explicitTime ? t?.minute : 0
            var d = cal.date(from: c)
            if let x = d, x <= now { d = cal.date(byAdding: .month, value: 1, to: x) }
            date = d
            if rule.isEmpty == false && rule.hasPrefix("week") { rule = "month:1" }
        }

        let bareRule = date == nil
        if date == nil {
            guard !rule.isEmpty else { return nil }
            // A bare repeat: start at the next natural slot.
            if rule.hasPrefix("minute") || rule.hasPrefix("hour") {
                date = next(after: now, rule: rule, from: now)
            } else {
                date = cal.date(bySettingHour: defaultHour, minute: 0, second: 0, of: now)
            }
        }
        guard var d = date else { return nil }
        if !explicitTime && !(rule.hasPrefix("minute") || rule.hasPrefix("hour")) {
            d = cal.date(bySettingHour: defaultHour, minute: 0, second: 0, of: d) ?? d
        }
        // "9am" after 9am means tomorrow; a repeat starting in the past rolls forward.
        if d <= now {
            // A repeat with no day ("every 2 weeks") starts at the next slot, not one interval out.
            if bareRule && !(rule.hasPrefix("minute") || rule.hasPrefix("hour")) {
                d = Calendar.current.date(byAdding: .day, value: 1, to: d) ?? d
            } else if !rule.isEmpty { d = next(after: now, rule: rule, from: d) }
            else if !explicitDay { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
        }
        if rule == "weekdays" { d = nextWeekday(d) }
        return Parsed(date: d, rule: rule)
    }

    /// The first occurrence of `rule` after `after`, stepping from `from`.
    public static func next(after: Date, rule: String, from: Date) -> Date {
        let cal = Calendar.current
        if rule == "weekdays" {
            var d = from
            repeat { d = cal.date(byAdding: .day, value: 1, to: d)! } while d <= after || cal.isDateInWeekend(d)
            return d
        }
        let parts = rule.split(separator: ":")
        guard parts.count == 2, let n = Int(parts[1]), n > 0 else { return cal.date(byAdding: .day, value: 1, to: from)! }
        let comp: Calendar.Component = ["minute": .minute, "hour": .hour, "day": .day, "week": .weekOfYear,
                                        "month": .month, "year": .year][String(parts[0])] ?? .day
        var d = from
        var guardCount = 0
        repeat { d = cal.date(byAdding: comp, value: n, to: d)!; guardCount += 1 } while d <= after && guardCount < 100_000
        return d
    }

    private static func nextWeekday(_ d: Date) -> Date {
        let cal = Calendar.current
        var x = d
        while cal.isDateInWeekend(x) { x = cal.date(byAdding: .day, value: 1, to: x)! }
        return x
    }

    /// "every weekday", "every 2 hours", "monthly".
    public static func describe(rule: String) -> String {
        if rule.isEmpty { return "" }
        if rule == "weekdays" { return "every weekday" }
        let p = rule.split(separator: ":")
        guard p.count == 2, let n = Int(p[1]) else { return rule }
        let unit = String(p[0])
        if n == 1 { return ["day": "daily", "week": "weekly", "month": "monthly", "year": "yearly"][unit] ?? "every \(unit)" }
        return "every \(n) \(unit)s"
    }

    /// Compact time for a row: "3:30 PM", "tue 9:00 AM", "nov 30".
    public static func short(_ ms: Int64, now: Date = Date()) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInTomorrow(d) { return "tmrw " + d.formatted(date: .omitted, time: .shortened) }
        if let days = cal.dateComponents([.day], from: now, to: d).day, abs(days) < 6 {
            return d.formatted(.dateTime.weekday(.abbreviated)).lowercased() + " " + d.formatted(date: .omitted, time: .shortened)
        }
        return d.formatted(.dateTime.month(.abbreviated).day()).lowercased()
    }

    /// Long form for details: "Fri, Nov 21 at 9:00 AM · every weekday".
    public static func long(_ ms: Int64, rule: String) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let base = d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        let r = describe(rule: rule)
        return r.isEmpty ? base : base + " · " + r
    }
}
