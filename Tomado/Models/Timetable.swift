import Foundation

// MARK: - Period

/// 時限（1コマ）。時刻は 0:00 からの「分」で持つ（タイムゾーン非依存にするため）
public struct TimetablePeriod: Codable, Equatable, Identifiable {
    public var index: Int  // 1 始まりの時限番号
    public var startMinutes: Int  // 0:00 からの分
    public var endMinutes: Int

    public var id: String { "\(index)-\(startMinutes)-\(endMinutes)" }
    public var lengthMinutes: Int { max(0, endMinutes - startMinutes) }

    public init(index: Int, startMinutes: Int, endMinutes: Int) {
        self.index = index
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }

    public init(index: Int, start: String, end: String) {
        self.index = index
        self.startMinutes = Timetable.minutes(from: start) ?? 0
        self.endMinutes = Timetable.minutes(from: end) ?? 0
    }
}

// MARK: - Timetable

/// 1日の時限表。テキスト（`1  09:00-10:40`）と相互変換できる
public struct Timetable: Codable, Equatable {
    public var periods: [TimetablePeriod]

    public init(periods: [TimetablePeriod]) {
        self.periods = periods
    }

    /// 既定の時間割（100分 × 4 コマ）
    public static let standard = Timetable(periods: [
        TimetablePeriod(index: 1, start: "09:00", end: "10:40"),
        TimetablePeriod(index: 2, start: "10:50", end: "12:30"),
        TimetablePeriod(index: 3, start: "13:30", end: "15:10"),
        TimetablePeriod(index: 4, start: "15:20", end: "17:00"),
    ])

    public var isEmpty: Bool { periods.isEmpty }

    /// 外から来た時限表（保存データ・手で書き換えられた plist）を安全な形に正す。
    /// 逆順・重なり・0 長・24 時をまたぐコマを落とし、番号を振り直す
    public func sanitized() -> Timetable {
        var result: [TimetablePeriod] = []
        for period in periods.sorted(by: { $0.startMinutes < $1.startMinutes }) {
            guard period.startMinutes >= 0,
                period.endMinutes > period.startMinutes,
                period.endMinutes <= 24 * 60
            else { continue }
            if let last = result.last, period.startMinutes < last.endMinutes { continue }
            result.append(
                TimetablePeriod(
                    index: result.count + 1,
                    startMinutes: period.startMinutes,
                    endMinutes: period.endMinutes
                ))
        }
        return Timetable(periods: result)
    }

    // MARK: Text form

    /// `1  09:00-10:40` 形式のテキスト
    public var text: String {
        periods
            .map { "\($0.index)  \(Timetable.hhmm($0.startMinutes))-\(Timetable.hhmm($0.endMinutes))" }
            .joined(separator: "\n")
    }

    /// テキストを寛容にパースする。`1 09:00-10:40` / `09:00〜10:40` / `1限 9:00 - 10:40` などを受ける。
    /// 戻り値の errors は「無視した行」の説明（UI に出す用、空なら完全に読めた）
    public static func parse(_ text: String) -> (timetable: Timetable, errors: [Int]) {
        var parsed: [(start: Int, end: Int)] = []
        var errors: [Int] = []

        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // 空行とコメント行は黙って読み飛ばす
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }

            // 12 時間表記は 24 時間表記と区別できない（1:30 PM を 01:30 と読んでしまう）。
            // 黙って夜の時間割を組むより、読めなかったと言う
            guard !mentionsMeridiem(line) else {
                errors.append(offset + 1)
                continue
            }

            // 1 行に複数コマ書かれていても取りこぼさない（貼り付けで 1 行になりがち）
            let times = clockTimes(in: line)
            var pairs = 0
            var index = 0
            while index + 1 < times.count {
                if times[index] < times[index + 1] {
                    parsed.append((times[index], times[index + 1]))
                    pairs += 1
                }
                index += 2
            }
            if pairs == 0 || times.count % 2 != 0 {
                errors.append(offset + 1)
            }
        }

        // 開始時刻でソートし直し、番号を振り直す（ユーザーが順不同で書いても壊れない）
        parsed.sort { $0.start < $1.start }

        var periods: [TimetablePeriod] = []
        for (i, p) in parsed.enumerated() {
            // 直前のコマと重なる行は捨てる（重なりを許すとフェーズ解決が破綻する）
            if let last = periods.last, p.start < last.endMinutes {
                errors.append(-(i + 1))  // 行番号が特定できないので負値で「重複」を表す
                continue
            }
            periods.append(
                TimetablePeriod(index: periods.count + 1, startMinutes: p.start, endMinutes: p.end))
        }

        return (Timetable(periods: periods), errors)
    }

    /// AM/PM（午前・午後）表記を含む行か。
    /// 単語の中の am/pm（Yamada など）を誤検出しないよう、語の切れ目を見る
    private static func mentionsMeridiem(_ line: String) -> Bool {
        if line.contains("午前") || line.contains("午後") { return true }

        let chars = Array(line.lowercased())
        for index in chars.indices {
            guard chars[index] == "a" || chars[index] == "p" else { continue }
            if index > 0, chars[index - 1].isLetter { continue }

            var cursor = chars.index(after: index)
            if cursor < chars.endIndex, chars[cursor] == "." {
                cursor = chars.index(after: cursor)
            }
            guard cursor < chars.endIndex, chars[cursor] == "m" else { continue }

            var tail = chars.index(after: cursor)
            if tail < chars.endIndex, chars[tail] == "." { tail = chars.index(after: tail) }
            if tail < chars.endIndex, chars[tail].isLetter { continue }
            return true
        }
        return false
    }

    /// 行に含まれる `H:MM` 形式をすべて拾う
    private static func clockTimes(in line: String) -> [Int] {
        var result: [Int] = []
        var token = ""

        func flush() {
            defer { token = "" }
            guard token.contains(":"), let value = minutes(from: token) else { return }
            result.append(value)
        }

        for ch in line {
            if ch.isNumber || ch == ":" {
                token.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    /// `9:00` / `09:00` / `24:00` を 0:00 からの分に。範囲外は nil
    public static func minutes(from string: String) -> Int? {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
            let hour = Int(parts[0]), let minute = Int(parts[1]),
            (0...24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        let total = hour * 60 + minute
        return total <= 24 * 60 ? total : nil
    }

    public static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

// MARK: - Segment

/// 時間割上の 1 区間の種類
public enum TimetableSegmentKind: String, Codable, Equatable {
    case work  // 作業ブロック
    case shortBreak  // 時限内の小休憩
    case longBreak  // 時限最後の休憩 + 次の時限までの休み時間（昼休み含む）
}

/// ある瞬間に「時間割のどこにいるか」
public struct TimetableSegment: Equatable {
    public let kind: TimetableSegmentKind
    public let start: Date
    public let end: Date
    /// 何限にいるか（longBreak は直前の時限番号）
    public let periodIndex: Int
    /// その時限の何セッション目か（1 始まり）
    public let sessionIndex: Int
    public let sessionsPerPeriod: Int
    /// 1 セッションの作業ブロック長（🍅 換算の分母）
    public let workSeconds: Int
    /// longBreak のとき、次の時限の番号と開始時刻
    public let nextPeriodIndex: Int?
    public let nextPeriodStart: Date?

    public var totalSeconds: Int { max(1, Int(end.timeIntervalSince(start).rounded())) }
}

// MARK: - Schedule

/// 時間割 + セッション分割ルールから、絶対時刻に対するフェーズを解決する
public struct TimetableSchedule {
    public let timetable: Timetable
    /// 1 時限あたりのセッション数（🐢 = 3 なら 🐇 = 6）
    public let sessionsPerPeriod: Int
    /// 作業:休憩 の比（4 なら 4:1）
    public let workBreakRatio: Double
    public let calendar: Calendar

    public init(
        timetable: Timetable, sessionsPerPeriod: Int, workBreakRatio: Double,
        calendar: Calendar = .current
    ) {
        self.timetable = timetable
        self.sessionsPerPeriod = max(1, sessionsPerPeriod)
        self.workBreakRatio = max(0.1, workBreakRatio)
        self.calendar = calendar
    }

    /// 1 セッション（作業 + 休憩）の長さ・作業長・休憩長を秒で返す
    public static func durations(periodMinutes: Int, sessions: Int, ratio: Double)
        -> (cycle: Int, work: Int, breakTime: Int)
    {
        let sessions = max(1, sessions)
        let ratio = max(0.1, ratio)
        let cycle = Double(periodMinutes * 60) / Double(sessions)
        let work = (cycle * ratio / (ratio + 1)).rounded()
        return (Int(cycle.rounded()), Int(work), Int((cycle - work).rounded()))
    }

    /// 指定時刻が時間割の内側なら区間を返す。外側（始業前・終業後・時間割が空）は nil
    public func segment(at date: Date) -> TimetableSegment? {
        let periods = timetable.periods
        guard let first = periods.first, let last = periods.last else { return nil }

        let dayStart = resolve(first.startMinutes, on: date)
        let dayEnd = resolve(last.endMinutes, on: date)
        guard date >= dayStart, date < dayEnd else { return nil }

        // 1. いずれかの時限の内側か
        for period in periods {
            let start = resolve(period.startMinutes, on: date)
            let end = resolve(period.endMinutes, on: date)
            guard date >= start, date < end else { continue }
            return segmentInside(period: period, start: start, end: end, at: date)
        }

        // 2. コマとコマの隙間（休み時間・昼休み）。直前の時限の最終休憩がここまで伸びている
        guard
            let previous = periods.last(where: { resolve($0.endMinutes, on: date) <= date }),
            let next = periods.first(where: { resolve($0.startMinutes, on: date) > date })
        else { return nil }

        let previousStart = resolve(previous.startMinutes, on: date)
        let previousEnd = resolve(previous.endMinutes, on: date)
        let work = grid(from: previousStart, to: previousEnd).work
        let nextStart = resolve(next.startMinutes, on: date)

        return TimetableSegment(
            kind: .longBreak,
            // 時限の内側から見たときと 1 ULP でも違うと「区切りを越えた」と誤判定するので、
            // 必ず同じ式（同じ順序の加算）で出す
            start: lastBreakStart(from: previousStart, to: previousEnd),
            end: nextStart,
            periodIndex: previous.index,
            sessionIndex: sessionsPerPeriod,
            sessionsPerPeriod: sessionsPerPeriod,
            workSeconds: Int(work.rounded()),
            nextPeriodIndex: next.index,
            nextPeriodStart: nextStart
        )
    }

    // MARK: Internals

    /// 1 セッションの長さと作業長。壁時計の分数ではなく実際の区間長から出すので、
    /// 夏時間の切替をまたぐ時限でもグリッドが時限からはみ出さない
    private func grid(from start: Date, to end: Date) -> (cycle: Double, work: Double) {
        let cycle = max(1, end.timeIntervalSince(start)) / Double(sessionsPerPeriod)
        return (cycle, cycle * workBreakRatio / (workBreakRatio + 1))
    }

    /// 時限の最後の休憩が始まる時刻。segmentInside と隙間側で同一の値になる必要がある
    private func lastBreakStart(from start: Date, to end: Date) -> Date {
        let g = grid(from: start, to: end)
        return start
            .addingTimeInterval(Double(sessionsPerPeriod - 1) * g.cycle)
            .addingTimeInterval(g.work)
    }

    private func segmentInside(period: TimetablePeriod, start: Date, end: Date, at date: Date)
        -> TimetableSegment
    {
        let (cycle, work) = grid(from: start, to: end)
        let offset = date.timeIntervalSince(start)
        let session = min(sessionsPerPeriod - 1, max(0, Int(offset / cycle)))
        let cycleStart = start.addingTimeInterval(Double(session) * cycle)
        let workEnd = cycleStart.addingTimeInterval(work)
        let workSeconds = Int(work.rounded())

        if date < workEnd {
            return TimetableSegment(
                kind: .work,
                start: cycleStart,
                end: workEnd,
                periodIndex: period.index,
                sessionIndex: session + 1,
                sessionsPerPeriod: sessionsPerPeriod,
                workSeconds: workSeconds,
                nextPeriodIndex: nil,
                nextPeriodStart: nil
            )
        }

        // 時限内の最後の休憩は、次の時限まで（休み時間・昼休みへ）そのまま伸ばす
        if session == sessionsPerPeriod - 1 {
            let next = timetable.periods.first { resolve($0.startMinutes, on: date) > date }
            let nextStart = next.map { resolve($0.startMinutes, on: date) }
            return TimetableSegment(
                kind: .longBreak,
                // 隙間側と同じ式を通す（workEnd と同値だが、式を共有して食い違いを防ぐ）
                start: lastBreakStart(from: start, to: end),
                end: nextStart ?? end,
                periodIndex: period.index,
                sessionIndex: session + 1,
                sessionsPerPeriod: sessionsPerPeriod,
                workSeconds: workSeconds,
                nextPeriodIndex: next?.index,
                nextPeriodStart: nextStart
            )
        }

        return TimetableSegment(
            kind: .shortBreak,
            start: workEnd,
            end: cycleStart.addingTimeInterval(cycle),
            periodIndex: period.index,
            sessionIndex: session + 1,
            sessionsPerPeriod: sessionsPerPeriod,
            workSeconds: workSeconds,
            nextPeriodIndex: nil,
            nextPeriodStart: nil
        )
    }

    /// その日の 0:00 からの分を絶対時刻へ。24:00 のようなはみ出しも扱えるようにしておく
    private func resolve(_ minutes: Int, on day: Date) -> Date {
        if minutes < 24 * 60,
            let exact = calendar.date(
                bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
        {
            return exact
        }
        return calendar.startOfDay(for: day).addingTimeInterval(Double(minutes) * 60)
    }
}
