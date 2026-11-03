import Foundation

/// ics（iCalendar）から「ある 1 日の時間を塞ぐ予定」を取り出す、最小限の読み取り
/// 対応: 時刻指定の VEVENT、TZID / UTC / 浮動時刻、DURATION、EXDATE、RECURRENCE-ID による差し替え、
/// RRULE の DAILY / WEEKLY(BYDAY) / MONTHLY / YEARLY と INTERVAL・COUNT・UNTIL。
/// それ以外の BYxxx を含む繰り返しは展開を諦め、初回だけ扱う（間違った日に塞ぐよりは取りこぼすほうを選ぶ）
enum ICSCalendar {
    struct Event {
        var uid = ""
        var summary = ""
        var start: Date?
        var end: Date?
        var duration: TimeInterval?
        var timeZone: TimeZone = .current
        var isAllDay = false
        var isFree = false       // TRANSP:TRANSPARENT（予定はあるが時間は空いている）
        var isCancelled = false
        var rrule: [String: String]?
        var exdates: Set<Date> = []
        var recurrenceId: Date?
    }

    struct Occurrence {
        let title: String
        let start: Date
        let end: Date
    }

    // MARK: - Parse

    static func parse(_ text: String) -> [Event] {
        // 折り返し行（次行の先頭が空白）を元の 1 行に戻す
        let unfolded = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")

        var events: [Event] = []
        var current: Event?
        for line in unfolded.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let head = line[..<colon].split(separator: ";").map(String.init)
            let value = String(line[line.index(after: colon)...])
            guard let name = head.first?.uppercased() else { continue }
            var params: [String: String] = [:]
            for param in head.dropFirst() {
                let pair = param.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { params[pair[0].uppercased()] = pair[1].trimmingCharacters(in: ["\""]) }
            }

            if name == "BEGIN", value == "VEVENT" { current = Event(); continue }
            if name == "END", value == "VEVENT" {
                if let event = current { events.append(event) }
                current = nil
                continue
            }
            guard current != nil else { continue }

            switch name {
            case "UID": current?.uid = value
            case "SUMMARY": current?.summary = unescape(value)
            case "DTSTART":
                if let parsed = parseDate(value, params: params) {
                    current?.start = parsed.date
                    current?.timeZone = parsed.timeZone
                    current?.isAllDay = parsed.isDate
                }
            case "DTEND": current?.end = parseDate(value, params: params)?.date
            case "DURATION": current?.duration = parseDuration(value)
            case "TRANSP": current?.isFree = value.uppercased() == "TRANSPARENT"
            case "STATUS": current?.isCancelled = value.uppercased() == "CANCELLED"
            case "RRULE":
                var rule: [String: String] = [:]
                for part in value.split(separator: ";") {
                    let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                    if pair.count == 2 { rule[pair[0].uppercased()] = pair[1] }
                }
                current?.rrule = rule
            case "EXDATE":
                for item in value.split(separator: ",") {
                    if let date = parseDate(String(item), params: params)?.date { current?.exdates.insert(date) }
                }
            case "RECURRENCE-ID": current?.recurrenceId = parseDate(value, params: params)?.date
            default: break
            }
        }
        return events
    }

    // MARK: - Occurrences

    /// interval に重なる、時間を塞ぐ予定（終日・空き時間・キャンセルは除く）
    static func occurrences(of events: [Event], in interval: DateInterval) -> [Occurrence] {
        // RECURRENCE-ID 付きの予定は、繰り返しの該当回を差し替える
        var overridden: Set<String> = []
        for event in events {
            if let rid = event.recurrenceId { overridden.insert("\(event.uid)|\(rid.timeIntervalSince1970)") }
        }

        var result: [Occurrence] = []
        for event in events where !event.isAllDay && !event.isFree && !event.isCancelled {
            guard let start = event.start else { continue }
            let length = event.end.map { $0.timeIntervalSince(start) } ?? event.duration ?? 0
            guard length > 0 else { continue }

            let starts = event.recurrenceId == nil ? occurrenceStarts(event, start: start, before: interval.end) : [start]
            for occurrence in starts {
                if event.recurrenceId == nil {
                    if event.exdates.contains(occurrence) { continue }
                    if overridden.contains("\(event.uid)|\(occurrence.timeIntervalSince1970)") { continue }
                }
                let end = occurrence.addingTimeInterval(length)
                if occurrence < interval.end && end > interval.start {
                    result.append(Occurrence(title: event.summary, start: occurrence, end: end))
                }
            }
        }
        return result
    }

    /// 繰り返しを展開した開始時刻（limit より前のものだけ）
    private static func occurrenceStarts(_ event: Event, start: Date, before limit: Date) -> [Date] {
        guard let rule = event.rrule, let freq = rule["FREQ"]?.uppercased() else { return [start] }
        let byParts = Set(rule.keys.filter { $0.hasPrefix("BY") })
        let supported = byParts.isEmpty || (freq == "WEEKLY" && byParts == ["BYDAY"])
        guard supported else { return [start] }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = event.timeZone
        let interval = max(1, Int(rule["INTERVAL"] ?? "") ?? 1)
        let count = rule["COUNT"].flatMap { Int($0) }
        // 日付だけの UNTIL はその日いっぱいまで含む
        let until = rule["UNTIL"].flatMap { parseDate($0, params: [:], fallbackZone: event.timeZone) }
            .map { $0.isDate ? $0.date.addingTimeInterval(86_400 - 1) : $0.date }

        var results: [Date] = []
        var produced = 0
        /// 1 回ぶん数える。打ち切り条件に達したら false
        func emit(_ date: Date) -> Bool {
            if let until, date > until { return false }
            if let count, produced >= count { return false }
            if date >= limit { return false }
            produced += 1
            results.append(date)
            return true
        }

        // 古い繰り返しでも止まるよう上限を置く（毎日 × 約 30 年）
        let maxSteps = 12_000
        switch freq {
        case "DAILY", "MONTHLY", "YEARLY":
            let unit: Calendar.Component = freq == "DAILY" ? .day : freq == "MONTHLY" ? .month : .year
            for step in 0..<maxSteps {
                guard let date = calendar.date(byAdding: unit, value: step * interval, to: start),
                      emit(date) else { break }
            }
        case "WEEKLY":
            // 週は月曜始まり（RFC 5545 の WKST 既定値）で数える
            let weekdayCodes = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
            let startWeekday = calendar.component(.weekday, from: start)
            let days = rule["BYDAY"].map { value in
                value.split(separator: ",").compactMap { weekdayCodes[String($0.suffix(2))] }
            } ?? [startWeekday]
            let mondayOffset: (Int) -> Int = { ($0 + 5) % 7 }  // 月=0 … 日=6
            let offsets = Set(days.map(mondayOffset)).sorted()
            guard let weekStart = calendar.date(byAdding: .day, value: -mondayOffset(startWeekday), to: start)
            else { return [start] }
            weeks: for week in 0..<(maxSteps / 7) {
                for offset in offsets {
                    guard let date = calendar.date(byAdding: .day, value: week * interval * 7 + offset, to: weekStart)
                    else { break weeks }
                    if date < start { continue }
                    if !emit(date) { break weeks }
                }
            }
        default:
            return [start]
        }
        return results
    }

    // MARK: - Values

    private static func parseDate(
        _ value: String, params: [String: String], fallbackZone: TimeZone = .current
    ) -> (date: Date, timeZone: TimeZone, isDate: Bool)? {
        let isDate = params["VALUE"]?.uppercased() == "DATE" || value.count == 8
        let isUTC = value.hasSuffix("Z")
        let zone: TimeZone =
            isUTC ? TimeZone(identifier: "UTC")!
            : params["TZID"].flatMap { TimeZone(identifier: $0) } ?? fallbackZone

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = isDate ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss"
        let raw = isUTC ? String(value.dropLast()) : value
        guard let date = formatter.date(from: raw) else { return nil }
        // UTC 指定の予定でも、繰り返しの展開はローカルの壁時計で行う
        return (date, isUTC ? .current : zone, isDate)
    }

    /// "PT1H30M" / "P1D" などを秒に
    private static func parseDuration(_ value: String) -> TimeInterval? {
        var seconds: TimeInterval = 0
        var number = ""
        var negative = false
        for char in value.uppercased() {
            switch char {
            case "-": negative = true
            case "P", "T", "+": continue
            case "0"..."9": number.append(char)
            default:
                guard let n = Double(number) else { return nil }
                switch char {
                case "W": seconds += n * 7 * 86_400
                case "D": seconds += n * 86_400
                case "H": seconds += n * 3_600
                case "M": seconds += n * 60
                case "S": seconds += n
                default: return nil
                }
                number = ""
            }
        }
        return negative ? -seconds : seconds
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\N", with: " ")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
