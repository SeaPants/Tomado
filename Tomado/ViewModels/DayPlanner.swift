import EventKit
import Foundation

/// 今日の計画（15 分マスのブロック）と、タイマーから拾った実績を持つ
/// 実績はタイマーの内部に手を入れず、一定間隔で「今なにを作業中か」を見て積む。
/// マス単位の粒度しか要らないので、数秒の誤差よりタイマー側の複雑さに巻き込まれないほうを取る
@MainActor
public final class DayPlanner: ObservableObject {
    @Published public private(set) var plan: DayPlan
    /// 提案を「今はいい」と閉じたブロック。同じブロックの間は出し直さない
    @Published public private(set) var dismissedSuggestionId: String?
    /// 表示の基準になる現在時刻（マスが変わったときだけ進めて、無駄な再描画を避ける）
    @Published public private(set) var currentSlot: Int

    /// カレンダーの予定で埋まっている時間（計画は置けない。斜線で見せる）
    /// Mac のカレンダー（EventKit）と ics の URL の両方から集める
    @Published public private(set) var busy: [BusyBlock] = []
    /// 計画パネルで最後に一番上に見えていたマス（開き直したときにそこから出す）。
    /// スクロールのたびに書かれるので @Published にはしない（全体の再描画を招く）
    public var panelTopSlot: Int?

    /// 設定のキー
    public static let startHourKey = "plannerStartHour"
    public static let endHourKey = "plannerEndHour"
    public static let calendarEnabledKey = "plannerCalendarEnabled"
    /// 読むカレンダーの ID。未設定なら全カレンダー
    public static let calendarIdsKey = "plannerCalendarIds"
    public static let icsURLsKey = "plannerICSURLs"
    public static let defaultStartHour = 8
    public static let defaultEndHour = 20
    /// 履歴を残す日数
    private static let historyDays = 30
    private static let samplingInterval: TimeInterval = 10
    /// ics を取り直す間隔
    private static let icsRefreshInterval: TimeInterval = 15 * 60

    private let storageURL: URL
    private var history: [String: DayPlan] = [:]
    private weak var timer: PomodoroTimer?
    private var sampler: Timer?
    private var lastSampleAt: Date?
    private let eventStore = EKEventStore()
    private var lastHourRange: [Int?] = []
    private var calendarSettings = CalendarSettings()
    private var macBusy: [BusyBlock] = [] { didSet { mergeBusy() } }
    private var icsBusy: [BusyBlock] = [] { didSet { mergeBusy() } }
    private var icsTexts: [String: String] = [:]  // URL -> 最後に取れた ics の中身
    private var lastICSFetchAt: Date?
    private var macReloadGeneration = 0  // 重なった読み直しのうち、最後のものだけ結果を使う

    /// カレンダー連携の設定。変わったときだけ読み直す
    private struct CalendarSettings: Equatable {
        var macEnabled = false
        var calendarIds: [String]?
        var icsURLs: [String] = []

        @MainActor static func current() -> CalendarSettings {
            let defaults = UserDefaults.standard
            return CalendarSettings(
                macEnabled: defaults.bool(forKey: DayPlanner.calendarEnabledKey),
                calendarIds: defaults.stringArray(forKey: DayPlanner.calendarIdsKey),
                icsURLs: defaults.stringArray(forKey: DayPlanner.icsURLsKey) ?? [])
        }
    }

    public init() {
        storageURL = FileManager.default.appStorageURL().appendingPathComponent("dayplans.json")
        let now = Date()
        currentSlot = DayPlan.slot(for: now)
        plan = DayPlan(day: DayPlan.dayKey(for: now))
        load()
        observeSettingsAndCalendar()
    }

    /// 設定（表示範囲・カレンダー連携）とカレンダー側の変更に追従する
    /// （DayPlanner はアプリと同じ寿命なので明示的な removeObserver は不要）
    private func observeSettingsAndCalendar() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.settingsDidChange() }
        }
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: eventStore, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadMacBusy() }
        }
        settingsDidChange()
    }

    private func settingsDidChange() {
        // didChange は無関係なキーの書き込みでも飛んでくるので、範囲が変わったときだけ描き直す
        let defaults = UserDefaults.standard
        let range = [defaults.object(forKey: Self.startHourKey) as? Int,
                     defaults.object(forKey: Self.endHourKey) as? Int]
        if range != lastHourRange {
            lastHourRange = range
            objectWillChange.send()
        }
        let newSettings = CalendarSettings.current()
        guard newSettings != calendarSettings else { return }
        let urlsChanged = newSettings.icsURLs != calendarSettings.icsURLs
        calendarSettings = newSettings
        reloadMacBusy()
        if urlsChanged { refreshICS() }
    }

    /// タイマーを見て実績を積み始める
    public func attach(timer: PomodoroTimer) {
        self.timer = timer
        sampler?.invalidate()
        let ticker = Timer.scheduledTimer(withTimeInterval: Self.samplingInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.sample(now: Date()) }
        }
        RunLoop.main.add(ticker, forMode: .common)
        sampler = ticker
    }

    private func sample(now: Date) {
        rollOverIfNeeded(now)
        let slot = DayPlan.slot(for: now)
        if slot != currentSlot { currentSlot = slot }

        if let last = lastICSFetchAt, now.timeIntervalSince(last) > Self.icsRefreshInterval {
            refreshICS()
        }

        defer { lastSampleAt = now }
        guard let timer, timer.isRunning, timer.currentPhase == .work, !timer.isInterruptionMode,
              let taskId = timer.currentTask?.id, let last = lastSampleAt else { return }
        // スリープ明けなどで間が空いても、その空白は作業として数えない
        let delta = Int(min(now.timeIntervalSince(last), Self.samplingInterval * 2).rounded())
        guard delta > 0 else { return }
        plan.worked[slot, default: [:]][taskId, default: 0] += delta
        save()
    }

    private func rollOverIfNeeded(_ now: Date) {
        let today = DayPlan.dayKey(for: now)
        guard plan.day != today else { return }
        history[plan.day] = plan
        plan = history[today] ?? DayPlan(day: today)
        dismissedSuggestionId = nil
        save()
        reloadMacBusy()
        rebuildICSBusy()
    }

    // MARK: - Calendar

    /// 今日の範囲（0:00〜翌 0:00）
    private func todayInterval() -> DateInterval {
        let dayStart = Calendar.current.startOfDay(for: Date())
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        return DateInterval(start: dayStart, end: dayEnd)
    }

    /// 予定の時間帯をマスにする。終わりはマスの途中なら切り上げ（10:40 終わりなら 10:45 まで塞ぐ）
    private func busyBlock(id: String, title: String, start: Date, end: Date, in day: DateInterval) -> BusyBlock? {
        let start = max(start, day.start)
        let end = min(end, day.end)
        guard end > start else { return nil }
        let startSlot = DayPlan.slot(for: start)
        let endMinutes = Int(end.timeIntervalSince(day.start) / 60)
        let endSlot = (endMinutes + DayPlan.slotMinutes - 1) / DayPlan.slotMinutes
        return BusyBlock(id: id, title: title, startSlot: startSlot, endSlot: max(startSlot + 1, endSlot))
    }

    private func mergeBusy() {
        busy = (macBusy + icsBusy).sorted { $0.startSlot < $1.startSlot }
    }

    /// Mac のカレンダー（選んだものだけ）から今日の予定を引き直す。初回は許可を求める
    public func reloadMacBusy() {
        let settings = calendarSettings
        macReloadGeneration += 1
        let generation = macReloadGeneration
        guard settings.macEnabled else {
            macBusy = []
            return
        }
        Task { @MainActor in
            let granted = await ensureCalendarAccess()
            // 許可ダイアログを待つ間に設定が変わっていたら、この結果は捨てる
            guard generation == macReloadGeneration else { return }
            guard granted else {
                macBusy = []
                return
            }
            var calendars: [EKCalendar]?
            if let ids = settings.calendarIds {
                calendars = eventStore.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
                // 空配列を渡すと全カレンダー扱いになるので、何も選んでいなければ読まない
                if calendars?.isEmpty == true {
                    macBusy = []
                    return
                }
            }
            let day = todayInterval()
            let predicate = eventStore.predicateForEvents(withStart: day.start, end: day.end, calendars: calendars)
            macBusy = eventStore.events(matching: predicate)
                // 終日予定と「空き時間」扱いの予定は作業時間を塞がない
                .filter { !$0.isAllDay && $0.availability != .free }
                .compactMap { event in
                    busyBlock(
                        id: "ek:" + (event.eventIdentifier ?? UUID().uuidString),
                        title: event.title ?? "", start: event.startDate, end: event.endDate, in: day)
                }
        }
    }

    /// ics の URL を取り直す。取れなかった URL は前回の中身（ディスクのキャッシュ）を使い続ける
    public func refreshICS() {
        lastICSFetchAt = Date()
        let urls = calendarSettings.icsURLs
        icsTexts = icsTexts.filter { urls.contains($0.key) }
        for url in urls where icsTexts[url] == nil {
            if let cached = try? String(contentsOf: icsCacheURL(for: url), encoding: .utf8) {
                icsTexts[url] = cached
            }
        }
        rebuildICSBusy()

        for urlString in urls {
            // webcal:// は https:// の別名
            let normalized = urlString.replacingOccurrences(of: "webcal://", with: "https://")
            guard let url = URL(string: normalized) else { continue }
            Task { @MainActor in
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                      let text = String(data: data, encoding: .utf8), text.contains("BEGIN:VCALENDAR"),
                      calendarSettings.icsURLs.contains(urlString) else { return }
                icsTexts[urlString] = text
                try? text.write(to: icsCacheURL(for: urlString), atomically: true, encoding: .utf8)
                rebuildICSBusy()
            }
        }
    }

    private func rebuildICSBusy() {
        let day = todayInterval()
        icsBusy = icsTexts.sorted { $0.key < $1.key }.flatMap { url, text in
            ICSCalendar.occurrences(of: ICSCalendar.parse(text), in: day).enumerated().compactMap { index, occurrence in
                busyBlock(
                    id: "ics:\(url)#\(index)", title: occurrence.title,
                    start: occurrence.start, end: occurrence.end, in: day)
            }
        }
    }

    private func icsCacheURL(for url: String) -> URL {
        var hash: UInt64 = 5381
        for byte in url.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        let dir = FileManager.default.appStorageURL().appendingPathComponent("ics-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(hash).ics")
    }

    private func ensureCalendarAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            return (try? await eventStore.requestFullAccessToEvents()) ?? false
        default:
            return false
        }
    }

    public func isBusy(_ slot: Int) -> Bool {
        busy.contains { $0.contains(slot) }
    }

    // MARK: - Editing

    /// タスクをマスに置く。既存ブロックの上なら、そのブロックのタスクを差し替える
    /// - Returns: 置けたら true（予定で埋まっているマスには置けない）
    @discardableResult
    public func place(taskId: String, at slot: Int, length: Int = 2) -> Bool {
        guard (0..<DayPlan.slotsPerDay).contains(slot), !isBusy(slot) else { return false }
        if let index = plan.blocks.firstIndex(where: { $0.contains(slot) }) {
            plan.blocks[index].taskId = taskId
        } else {
            let fitted = min(length, freeSlots(after: slot, excluding: nil))
            plan.blocks.append(TimeBlock(taskId: taskId, startSlot: slot, length: max(1, fitted)))
        }
        save()
        return true
    }

    /// ブロックを別の開始マスへ動かす。他のブロックと重なるなら動かさない
    public func move(blockId: String, to startSlot: Int) {
        guard let index = plan.blocks.firstIndex(where: { $0.id == blockId }) else { return }
        let length = plan.blocks[index].length
        let start = min(max(0, startSlot), DayPlan.slotsPerDay - length)
        let overlaps = plan.blocks.contains {
            $0.id != blockId && $0.startSlot < start + length && start < $0.endSlot
        } || busy.contains { $0.startSlot < start + length && start < $0.endSlot }
        guard !overlaps, plan.blocks[index].startSlot != start else { return }
        plan.blocks[index].startSlot = start
        save()
    }

    /// ブロックの長さを変える。次のブロックや日付の終わりにぶつかるところで止める
    public func resize(blockId: String, to length: Int) {
        guard let index = plan.blocks.firstIndex(where: { $0.id == blockId }) else { return }
        let block = plan.blocks[index]
        let fitted = min(max(1, length), freeSlots(after: block.startSlot, excluding: blockId))
        guard fitted != block.length else { return }
        plan.blocks[index].length = fitted
        save()
    }

    public func remove(blockId: String) {
        plan.blocks.removeAll { $0.id == blockId }
        save()
    }

    /// 消えたタスクのブロックを取り除く。残すと、描かれないのにマスを塞ぎ続けて
    /// ドロップや移動が見えない何かにぶつかる
    public func pruneBlocks(keepingTaskIds taskIds: Set<String>) {
        let kept = plan.blocks.filter { taskIds.contains($0.taskId) }
        guard kept.count != plan.blocks.count else { return }
        plan.blocks = kept
        save()
    }

    /// slot から数えて、他のブロックか予定にぶつかるまで何マス空いているか
    private func freeSlots(after slot: Int, excluding blockId: String?) -> Int {
        let nextStart = (plan.blocks.filter { $0.id != blockId }.map(\.startSlot) + busy.map(\.startSlot))
            .filter { $0 > slot }
            .min() ?? DayPlan.slotsPerDay
        return nextStart - slot
    }

    // MARK: - Suggestion

    /// 今のマスに計画されているのに、別のタスクを選んでいるときの提案先
    /// 切り替えは提案に留める。作業中のタスクを時刻だけで勝手に差し替えない
    public func suggestion(currentTaskId: String?, tasks: [TodoTask]) -> (block: TimeBlock, task: TodoTask)? {
        guard let block = plan.block(at: currentSlot),
              block.id != dismissedSuggestionId,
              block.taskId != currentTaskId,
              let task = tasks.first(where: { $0.id == block.taskId && !$0.isCompleted }) else { return nil }
        return (block, task)
    }

    public func dismissSuggestion(blockId: String) {
        dismissedSuggestionId = blockId
    }

    // MARK: - Display range

    /// 表示する範囲（設定の時間帯を、計画・実績・現在時刻を含むよう広げる）
    public var visibleSlots: Range<Int> {
        let defaults = UserDefaults.standard
        let startHour = defaults.object(forKey: Self.startHourKey) as? Int ?? Self.defaultStartHour
        let endHour = defaults.object(forKey: Self.endHourKey) as? Int ?? Self.defaultEndHour
        var lower = startHour * 4
        var upper = max(endHour, startHour + 1) * 4
        for block in plan.blocks {
            lower = min(lower, block.startSlot)
            upper = max(upper, block.endSlot)
        }
        for slot in plan.worked.keys {
            lower = min(lower, slot)
            upper = max(upper, slot + 1)
        }
        lower = min(lower, currentSlot)
        upper = max(upper, currentSlot + 1)
        // 時の区切りで揃える
        return (lower / 4 * 4)..<min(DayPlan.slotsPerDay, (upper + 3) / 4 * 4)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([String: DayPlan].self, from: data) else { return }
        history = decoded
        if let today = history[plan.day] { plan = today }
    }

    private func save() {
        history[plan.day] = plan
        // 古い日は落とす（日付キーは yyyy-MM-dd なので文字列比較で並ぶ）
        let keep = Set(history.keys.sorted().suffix(Self.historyDays))
        history = history.filter { keep.contains($0.key) }
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
