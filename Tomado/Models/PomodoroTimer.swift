import AVFoundation
import AppKit
import Foundation
import _Concurrency

@MainActor
public class PomodoroTimer: ObservableObject {

    // 介入記録の構造体
    public struct InterruptionRecord: Codable, Identifiable {
        public let id: String
        public let startTime: Date
        public let endTime: Date
        public let durationSeconds: Int
        public let interruptionType: String?  // 中断タイプ
        public let selectedAction: String?  // 選択された行動

        public init(
            id: String = UUID().uuidString, startTime: Date, endTime: Date, durationSeconds: Int,
            interruptionType: String? = nil, selectedAction: String? = nil
        ) {
            self.id = id
            self.startTime = startTime
            self.endTime = endTime
            self.durationSeconds = durationSeconds
            self.interruptionType = interruptionType
            self.selectedAction = selectedAction
        }
    }

    public enum Phase: String {
        case work = "work"
        case break_ = "break"
        case longBreak = "longBreak"

        var title: String {
            switch self {
            case .work: return "作業"
            case .break_: return "休憩"
            case .longBreak: return "長い休憩"
            }
        }
    }

    @Published public private(set) var currentPhase: Phase = .work
    @Published public private(set) var remainingSeconds: Int
    @Published public private(set) var isRunning = false
    @Published public private(set) var sessionPomodoros = 0
    @Published public private(set) var currentTask: TodoTask?
    @Published public var isInterruptionMode = false  // 雑務・介入モード
    @Published public private(set) var interruptionStartTime: Date?  // 介入開始時刻
    @Published public private(set) var interruptionRecords: [InterruptionRecord] = []  // 介入記録
    @Published public private(set) var currentInterruptionType: String?  // 現在の中断タイプ
    @Published public private(set) var currentInterruptionAction: String?  // 現在の中断行動

    // タスクごとの実作業時間追跡（雑務時間を除外）
    private var accumulatedWorkSecondsByTask: [String: Int] = [:]  // taskId -> 累積実作業秒数

    // 雑務・介入時間の累積（タイマー動作中のみ）
    private var accumulatedInterruptionSeconds: Int = 0  // タイマー動作中の雑務時間

    // タイムスタンプベースのタイマー追跡
    private var phaseStartTime: Date?  // 現在のフェーズ開始時刻
    private var pausedAt: Date?  // 一時停止時刻
    private var totalPausedDuration: TimeInterval = 0  // 累積一時停止時間

    // タスクごとの作業開始時刻と一時停止時間
    private var taskStartTime: Date?  // 現在のタスクの作業開始時刻
    private var taskPausedDuration: TimeInterval = 0  // 現在のタスクの一時停止時間

    @Published public var workDuration: Int {
        didSet {
            saveSettings()
        }
    }
    @Published public var breakDuration: Int {
        didSet {
            saveSettings()
        }
    }
    @Published public var longBreakDuration: Int {
        didSet {
            saveSettings()
        }
    }
    @Published public var pomodorosUntilLongBreak: Int {
        didSet {
            saveSettings()
        }
    }
    @Published public var soundEnabled: Bool = true {
        didSet {
            saveSettings()
        }
    }
    @Published public var completionSound: String = "Glass" {
        didSet {
            saveSettings()
        }
    }
    @Published public var separateStartEndSounds: Bool = false {
        didSet {
            saveSettings()
        }
    }
    @Published public var startSound: String = "Ping" {
        didSet {
            saveSettings()
        }
    }
    @Published public var soundVolume: Double = 1.0 {
        didSet {
            saveSettings()
        }
    }
    @Published public private(set) var availableSounds: [String] = []

    private var timer: Timer?
    private var isInitializing = false
    private var audioPlayer: AVAudioPlayer?

    public init(
        workMinutes: Int = 25, breakMinutes: Int = 5, longBreakMinutes: Int = 15,
        pomodorosUntilLongBreak: Int = 4
    ) {
        isInitializing = true

        self.workDuration = workMinutes * 60
        self.breakDuration = breakMinutes * 60
        self.longBreakDuration = longBreakMinutes * 60
        self.pomodorosUntilLongBreak = pomodorosUntilLongBreak
        self.remainingSeconds = workMinutes * 60

        isInitializing = false

        // 保存された設定を読み込み
        loadSettings()

        // 利用可能なサウンドを取得
        loadAvailableSounds()

        // タイマー状態を復元
        loadTimerState()

        // 介入記録を復元
        loadInterruptionRecords()

        // アプリケーションの状態変化を監視
        setupApplicationObservers()
    }

    // MARK: - Application State Observers

    /// アプリケーションの状態変化を監視するオブザーバーを設定
    private func setupApplicationObservers() {
        // アプリがアクティブになった時
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppDidBecomeActive()
            }
        }

        // アプリが非アクティブになった時
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppWillResignActive()
            }
        }
    }

    /// アプリがアクティブになった時の処理
    private func handleAppDidBecomeActive() {
        guard isRunning, let startTime = phaseStartTime else { return }

        // タイムスタンプベースで正確な残り時間を再計算
        let phaseDuration: Int
        switch currentPhase {
        case .work:
            phaseDuration = workDuration
        case .break_:
            phaseDuration = breakDuration
        case .longBreak:
            phaseDuration = longBreakDuration
        }

        let elapsedTime = Date().timeIntervalSince(startTime) - totalPausedDuration
        let newRemainingSeconds = max(0, phaseDuration - Int(elapsedTime))

        // フェーズが完了していた場合
        if newRemainingSeconds <= 0 {
            remainingSeconds = 0
            handlePhaseCompletion()
        } else {
            remainingSeconds = newRemainingSeconds
        }

        // 累積時間も更新
        if isInterruptionMode {
            // 介入モード: interruptionStartTimeからの経過時間を再計算
            if let interruptionStart = interruptionStartTime {
                let interruptionElapsed = Date().timeIntervalSince(interruptionStart)
                accumulatedInterruptionSeconds = Int(interruptionElapsed)
            }
        } else if currentPhase == .work {
            // 通常の作業モード: taskStartTimeからの経過時間を再計算
            if let taskId = currentTask?.id, let taskStart = taskStartTime {
                let taskElapsed = Date().timeIntervalSince(taskStart) - taskPausedDuration
                accumulatedWorkSecondsByTask[taskId] = Int(taskElapsed)
            }
        }
    }

    /// アプリが非アクティブになった時の処理
    private func handleAppWillResignActive() {
        // 現在の状態を保存
        if isRunning {
            saveTimerState()
        }
    }

    // MARK: - Settings Persistence

    private func saveSettings() {
        // 初期化中は保存しない
        guard !isInitializing else { return }

        UserDefaults.standard.set(workDuration, forKey: "pomodoro_work_duration")
        UserDefaults.standard.set(breakDuration, forKey: "pomodoro_break_duration")
        UserDefaults.standard.set(longBreakDuration, forKey: "pomodoro_long_break_duration")
        UserDefaults.standard.set(pomodorosUntilLongBreak, forKey: "pomodoro_cycle_count")
        UserDefaults.standard.set(soundEnabled, forKey: "pomodoro_sound_enabled")
        UserDefaults.standard.set(completionSound, forKey: "pomodoro_completion_sound")
        UserDefaults.standard.set(
            separateStartEndSounds, forKey: "pomodoro_separate_start_end_sounds")
        UserDefaults.standard.set(startSound, forKey: "pomodoro_start_sound")
        UserDefaults.standard.set(soundVolume, forKey: "pomodoro_sound_volume")
    }

    private func loadSettings() {
        isInitializing = true

        // 保存された設定があれば読み込み、なければデフォルト値を使用
        if UserDefaults.standard.object(forKey: "pomodoro_work_duration") != nil {
            workDuration = UserDefaults.standard.integer(forKey: "pomodoro_work_duration")
        }

        if UserDefaults.standard.object(forKey: "pomodoro_break_duration") != nil {
            breakDuration = UserDefaults.standard.integer(forKey: "pomodoro_break_duration")
        }

        if UserDefaults.standard.object(forKey: "pomodoro_long_break_duration") != nil {
            longBreakDuration = UserDefaults.standard.integer(
                forKey: "pomodoro_long_break_duration")
        }

        if UserDefaults.standard.object(forKey: "pomodoro_cycle_count") != nil {
            pomodorosUntilLongBreak = UserDefaults.standard.integer(forKey: "pomodoro_cycle_count")
        }

        if UserDefaults.standard.object(forKey: "pomodoro_sound_enabled") != nil {
            soundEnabled = UserDefaults.standard.bool(forKey: "pomodoro_sound_enabled")
        }

        if let sound = UserDefaults.standard.string(forKey: "pomodoro_completion_sound") {
            completionSound = sound
        }

        if UserDefaults.standard.object(forKey: "pomodoro_separate_start_end_sounds") != nil {
            separateStartEndSounds = UserDefaults.standard.bool(
                forKey: "pomodoro_separate_start_end_sounds")
        }

        if let sound = UserDefaults.standard.string(forKey: "pomodoro_start_sound") {
            startSound = sound
        }

        if UserDefaults.standard.object(forKey: "pomodoro_sound_volume") != nil {
            soundVolume = UserDefaults.standard.double(forKey: "pomodoro_sound_volume")
        }

        // 現在のフェーズに応じて remainingSeconds を更新
        switch currentPhase {
        case .work:
            remainingSeconds = workDuration
        case .break_:
            remainingSeconds = breakDuration
        case .longBreak:
            remainingSeconds = longBreakDuration
        }

        isInitializing = false
    }

    // MARK: - Timer State Persistence

    /// タイマーの現在状態を保存
    private func saveTimerState() {
        UserDefaults.standard.set(remainingSeconds, forKey: "pomodoro_remaining_seconds")
        UserDefaults.standard.set(currentPhase.rawValue, forKey: "pomodoro_current_phase")
        UserDefaults.standard.set(sessionPomodoros, forKey: "pomodoro_session_count")

        // タイムスタンプを保存
        if let startTime = phaseStartTime {
            UserDefaults.standard.set(
                startTime.timeIntervalSince1970, forKey: "pomodoro_phase_start_time")
        } else {
            UserDefaults.standard.removeObject(forKey: "pomodoro_phase_start_time")
        }

        UserDefaults.standard.set(totalPausedDuration, forKey: "pomodoro_total_paused_duration")

        // 累積作業時間を保存
        saveAccumulatedWorkTime()
    }

    /// 累積作業時間を保存
    private func saveAccumulatedWorkTime() {
        if let encoded = try? JSONEncoder().encode(accumulatedWorkSecondsByTask) {
            UserDefaults.standard.set(encoded, forKey: "pomodoro_accumulated_work_time")
        }
    }

    /// 累積作業時間を読み込み
    private func loadAccumulatedWorkTime() {
        if let data = UserDefaults.standard.data(forKey: "pomodoro_accumulated_work_time"),
            let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
        {
            accumulatedWorkSecondsByTask = decoded
        }
    }

    /// タイマーの状態を復元
    private func loadTimerState() {
        if UserDefaults.standard.object(forKey: "pomodoro_remaining_seconds") != nil {
            remainingSeconds = UserDefaults.standard.integer(forKey: "pomodoro_remaining_seconds")
        }

        if let phaseRawValue = UserDefaults.standard.object(forKey: "pomodoro_current_phase")
            as? String,
            let savedPhase = Phase(rawValue: phaseRawValue)
        {
            currentPhase = savedPhase
        }

        if UserDefaults.standard.object(forKey: "pomodoro_session_count") != nil {
            sessionPomodoros = UserDefaults.standard.integer(forKey: "pomodoro_session_count")
        }

        // タイムスタンプを復元
        if let startTimeInterval = UserDefaults.standard.object(forKey: "pomodoro_phase_start_time")
            as? TimeInterval
        {
            phaseStartTime = Date(timeIntervalSince1970: startTimeInterval)
        }

        if UserDefaults.standard.object(forKey: "pomodoro_total_paused_duration") != nil {
            totalPausedDuration = UserDefaults.standard.double(
                forKey: "pomodoro_total_paused_duration")
        }

        // 累積作業時間を復元
        loadAccumulatedWorkTime()

        // 安全のため、復元時は常にタイマーを停止状態にする
        isRunning = false
    }

    // MARK: - Static Settings Access

    /// 設定されたポモドーロ作業時間（秒）を取得（インスタンス不要）
    public static var defaultWorkDuration: Int {
        return UserDefaults.standard.object(forKey: "pomodoro_work_duration") != nil
            ? UserDefaults.standard.integer(forKey: "pomodoro_work_duration") : 25 * 60
    }

    /// 設定された休憩時間（秒）を取得（インスタンス不要）
    public static var defaultBreakDuration: Int {
        return UserDefaults.standard.object(forKey: "pomodoro_break_duration") != nil
            ? UserDefaults.standard.integer(forKey: "pomodoro_break_duration") : 5 * 60
    }

    /// 設定された長い休憩時間（秒）を取得（インスタンス不要）
    public static var defaultLongBreakDuration: Int {
        return UserDefaults.standard.object(forKey: "pomodoro_long_break_duration") != nil
            ? UserDefaults.standard.integer(forKey: "pomodoro_long_break_duration") : 15 * 60
    }

    /// 設定された長い休憩までのポモドーロ数を取得（インスタンス不要）
    public static var defaultPomodorosUntilLongBreak: Int {
        return UserDefaults.standard.object(forKey: "pomodoro_cycle_count") != nil
            ? UserDefaults.standard.integer(forKey: "pomodoro_cycle_count") : 4
    }

    public func updateSettings(
        workMinutes: Int, breakMinutes: Int, longBreakMinutes: Int, pomodorosUntilLongBreak: Int
    ) {
        pause()

        isInitializing = true

        workDuration = workMinutes * 60
        breakDuration = breakMinutes * 60
        longBreakDuration = longBreakMinutes * 60
        self.pomodorosUntilLongBreak = pomodorosUntilLongBreak
        remainingSeconds = workDuration
        currentPhase = .work
        sessionPomodoros = 0

        isInitializing = false

        // 設定を保存
        saveSettings()
    }

    public func resetCycle() {
        pause()
        isInitializing = true
        currentPhase = .work
        remainingSeconds = workDuration
        sessionPomodoros = 0
        phaseStartTime = nil
        totalPausedDuration = 0
        taskStartTime = nil
        taskPausedDuration = 0

        // 実作業時間追跡をリセット
        accumulatedWorkSecondsByTask.removeAll()
        // 注: 雑務タイムは現在進行中のセッションがある可能性があるためリセットしない

        isInitializing = false
        saveTimerState()
    }

    public func start() {
        guard !isRunning else { return }

        isRunning = true

        // フェーズ開始時刻を設定（初回のみ）
        if phaseStartTime == nil {
            phaseStartTime = Date()
            totalPausedDuration = 0
        } else if let pausedTime = pausedAt {
            // 一時停止から再開する場合、一時停止時間を累積
            totalPausedDuration += Date().timeIntervalSince(pausedTime)
            pausedAt = nil
        }

        // 作業フェーズでタスクがある場合、タスク開始時刻を設定
        if currentPhase == .work && currentTask != nil && !isInterruptionMode {
            if taskStartTime == nil {
                taskStartTime = Date()
                taskPausedDuration = 0
            } else if let pausedTime = pausedAt {
                // タスクの一時停止から再開
                taskPausedDuration += Date().timeIntervalSince(pausedTime)
            }
        }

        timer?.invalidate()  // 既存のタイマーがあれば停止

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleTick()
            }
        }

        // Make sure timer runs on main run loop
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }

        if let task = currentTask {
            currentTask = task
            NotificationCenter.default.post(
                name: .taskUpdated,
                object: nil,
                userInfo: [
                    "task": task,
                    "source": "pomodoro_started",
                ]
            )
        }
    }

    public func pause() {
        guard isRunning else { return }

        isRunning = false
        pausedAt = Date()
        timer?.invalidate()
        timer = nil

        // 一時停止時に累積作業時間を記録（次回再開時のため）
        recordCurrentProgress()

        saveTimerState()
    }

    public func toggle() {
        if isRunning {
            pause()
        } else {
            start()
        }
    }

    public func skip() {
        pause()
        handlePhaseCompletion(skip: true)
        start()
    }

    public func reset() {
        // リセット前に現在の進捗を記録
        recordCurrentProgress()

        pause()
        phaseStartTime = nil
        totalPausedDuration = 0
        pausedAt = nil

        switch currentPhase {
        case .work:
            remainingSeconds = workDuration
            // 作業フェーズのリセット時は現在のタスクの実作業時間をリセット
            if let taskId = currentTask?.id {
                accumulatedWorkSecondsByTask[taskId] = 0
            }
            // タスク時刻もリセット
            taskStartTime = nil
            taskPausedDuration = 0
            // 雑務・介入時間もリセット
            accumulatedInterruptionSeconds = 0
        case .break_:
            remainingSeconds = breakDuration
        case .longBreak:
            remainingSeconds = longBreakDuration
        }
        saveTimerState()
    }

    /// 全ての累積がある未記録タスクの進捗を記録
    private func recordAllAccumulatedProgress() {
        guard currentPhase == .work else { return }

        // 累積時間があるタスクを全て処理
        for (taskId, seconds) in accumulatedWorkSecondsByTask {
            guard seconds > 0 else { continue }

            // タスクIDから経過ポモドーロを計算
            let elapsedSeconds = Double(seconds)
            let hundredthPomodoroSeconds = Double(workDuration) / 100.0
            let completedHundredths = floor(elapsedSeconds / hundredthPomodoroSeconds)
            let elapsedPomodoros = completedHundredths * 0.01

            guard elapsedPomodoros > 0 else { continue }

            // タスクを構築して通知（現在のタスクかどうかに関わらず）
            // 注: ここではタスクオブジェクトがないので、taskIdのみで通知
            NotificationCenter.default.post(
                name: .pomodoroProgressByTaskId,
                object: nil,
                userInfo: [
                    "taskId": taskId,
                    "elapsedPomodoros": elapsedPomodoros,
                ]
            )
        }

        // 全てのタスクの累積をリセット
        accumulatedWorkSecondsByTask.removeAll()

        // 注: 雑務・介入時間の記録はendInterruptionMode()でのみ行う
        // 一時停止時は累積を止めるだけで記録は作成しない
    }

    /// 現在の進捗を記録（一時停止・リセット時）
    private func recordCurrentProgress() {
        // 全ての累積がある未記録タスクを記録
        recordAllAccumulatedProgress()
    }

    private func handleTick() {
        // タイムスタンプベースで経過時間を計算
        guard let startTime = phaseStartTime else {
            // 開始時刻が設定されていない場合は従来の方法にフォールバック
            guard remainingSeconds > 0 else {
                handlePhaseCompletion()
                return
            }
            remainingSeconds -= 1
            if remainingSeconds % 30 == 0 {
                saveTimerState()
            }
            return
        }

        // 現在のフェーズの総時間を取得
        let phaseDuration: Int
        switch currentPhase {
        case .work:
            phaseDuration = workDuration
        case .break_:
            phaseDuration = breakDuration
        case .longBreak:
            phaseDuration = longBreakDuration
        }

        // 実際の経過時間を計算（一時停止時間を除く）
        let elapsedTime = Date().timeIntervalSince(startTime) - totalPausedDuration
        let newRemainingSeconds = max(0, phaseDuration - Int(elapsedTime))

        // フェーズ完了チェック
        if newRemainingSeconds <= 0 {
            remainingSeconds = 0
            handlePhaseCompletion()
            return
        }

        // 残り時間を更新（UIのため）
        remainingSeconds = newRemainingSeconds

        // 累積時間の計算（1秒ごと）
        if isInterruptionMode {
            // 雑務・介入モード: interruptionStartTimeからの経過時間を累積
            if let interruptionStart = interruptionStartTime {
                let interruptionElapsed = Date().timeIntervalSince(interruptionStart)
                accumulatedInterruptionSeconds = Int(interruptionElapsed)
            }
        }

        // 作業フェーズでの時間累積（雑務・介入モード時は除外）
        if currentPhase == .work && !isInterruptionMode {
            if let taskId = currentTask?.id, let taskStart = taskStartTime {
                // 通常モード: タスクの実作業時間を累積（タイムスタンプベース）
                // taskStartTimeからの経過時間（一時停止時間を除く）
                let taskElapsed = Date().timeIntervalSince(taskStart) - taskPausedDuration
                accumulatedWorkSecondsByTask[taskId] = Int(taskElapsed)
            }
        }

        // 30秒ごとに状態を保存（パフォーマンス配慮）
        if remainingSeconds % 30 == 0 {
            saveTimerState()
        }
    }

    private func handlePhaseCompletion(skip: Bool = false) {
        // Play completion sound
        if soundEnabled {
            playCompletionSound()
        }

        switch currentPhase {
        case .work:
            sessionPomodoros += 1

            // 全ての累積がある未記録タスクを記録
            recordAllAccumulatedProgress()

            if sessionPomodoros >= pomodorosUntilLongBreak {
                currentPhase = .longBreak
                remainingSeconds = longBreakDuration
                sessionPomodoros = 0
            } else {
                currentPhase = .break_
                remainingSeconds = breakDuration
            }

        case .break_, .longBreak:
            currentPhase = .work
            remainingSeconds = workDuration
        }

        // 新しいフェーズのためにタイムスタンプをリセット
        phaseStartTime = Date()
        totalPausedDuration = 0
        pausedAt = nil

        // 作業フェーズに移行する場合、タスク時刻をリセット
        if currentPhase == .work && currentTask != nil {
            taskStartTime = Date()
            taskPausedDuration = 0
        } else {
            // 休憩フェーズに移行する場合、タスク時刻をクリア
            taskStartTime = nil
            taskPausedDuration = 0
        }

        // フェーズ完了時に状態を保存
        saveTimerState()
    }

    private func playCompletionSound() {
        guard soundEnabled else {
            return
        }

        // 既存のaudioPlayerを適切に停止・解放
        audioPlayer?.stop()
        audioPlayer = nil

        // フェーズに応じて適切な音を選択
        // work完了時 → 終了音（completionSound）
        // 休憩完了時（work開始時） → 開始音（startSound）または終了音
        let targetSoundName: String
        if separateStartEndSounds && (currentPhase == .break_ || currentPhase == .longBreak) {
            // 休憩完了時（次はwork開始）→ 開始音を使用
            targetSoundName = startSound
        } else {
            // work完了時または、別々の音を使わない場合
            targetSoundName = completionSound
        }

        let effectiveVolume = min(Float(soundVolume), 1.0)
        var soundPlayed = false

        // 方法1: 選択されたサウンドを再生
        if let sound = NSSound(named: targetSoundName) {
            sound.volume = effectiveVolume
            soundPlayed = sound.play()
        }

        // 方法2: 選択されたサウンドが見つからない場合、システムサウンドファイルから直接読み込み
        if !soundPlayed, let soundURL = getSystemSoundURL(for: targetSoundName) {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: soundURL)
                audioPlayer?.volume = effectiveVolume
                soundPlayed = audioPlayer?.play() ?? false
            } catch {
                // サウンド再生失敗は無視
            }
        }

        // 方法3: 最後のフォールバック - システムビープ音
        if !soundPlayed {
            NSSound.beep()
        }
    }

    private func getSystemSoundURL(for soundName: String) -> URL? {
        // macOSのシステムサウンドディレクトリを検索
        let systemSoundPaths = [
            "/System/Library/Sounds/",
            "/Library/Sounds/",
            "~/Library/Sounds/".expandingTildeInPath,
        ]

        let extensions = ["aiff", "wav", "mp3", "m4a", "caf"]

        for path in systemSoundPaths {
            for ext in extensions {
                let fullPath = path + soundName + "." + ext
                let url = URL(fileURLWithPath: fullPath)
                if FileManager.default.fileExists(atPath: fullPath) {
                    return url
                }
            }
        }

        return nil
    }

    public func loadAvailableSounds() {
        var sounds: Set<String> = []

        // システムサウンドディレクトリを検索
        let systemSoundPaths = [
            "/System/Library/Sounds/",
            "/Library/Sounds/",
            "~/Library/Sounds/".expandingTildeInPath,
        ]

        let extensions = ["aiff", "wav", "mp3", "m4a", "caf"]

        for path in systemSoundPaths {
            guard let enumerator = FileManager.default.enumerator(atPath: path) else { continue }

            while let file = enumerator.nextObject() as? String {
                let fileURL = URL(fileURLWithPath: file)
                let fileName = fileURL.deletingPathExtension().lastPathComponent
                let fileExtension = fileURL.pathExtension.lowercased()

                if extensions.contains(fileExtension) {
                    sounds.insert(fileName)
                }
            }
        }

        // デフォルトサウンドを含める（システムで見つからない場合のみ）
        let defaultSounds = [
            "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse",
            "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
        ]

        for sound in defaultSounds {
            if !sounds.contains(sound) {
                sounds.insert(sound)
            }
        }

        // アルファベット順にソート
        availableSounds = Array(sounds).sorted()

        // 現在選択されているサウンドが利用可能リストにない場合、デフォルトに戻す
        if !availableSounds.contains(completionSound) {
            completionSound = availableSounds.first ?? "Glass"
        }
    }

    public func testPlaySound() {
        playCompletionSound()
    }

    public func setCurrentTask(_ task: TodoTask?) {
        // タスク切り替え時に、前のタスクの累積時間を記録
        if let oldTask = currentTask, oldTask.id != task?.id {
            recordCurrentProgress()

            // 新しいタスクの開始時刻をリセット
            if isRunning && currentPhase == .work && !isInterruptionMode {
                taskStartTime = Date()
                taskPausedDuration = 0
            }
        }

        currentTask = task

        // 初めてタスクが設定される場合（タイマー開始前など）
        if task != nil && taskStartTime == nil && isRunning && currentPhase == .work
            && !isInterruptionMode
        {
            taskStartTime = Date()
            taskPausedDuration = 0
        }
    }

    /// 指定したタスクの累積時間をクリア（スキップ・完了時に二重記録を防ぐため）
    public func clearAccumulatedTime(for taskId: String) {
        accumulatedWorkSecondsByTask.removeValue(forKey: taskId)
    }

    /// 中断モードを開始（新しいインターフェース）
    public func startInterruptionMode(type: String, action: String?) {
        if !isInterruptionMode {
            isInterruptionMode = true
            interruptionStartTime = Date()
            accumulatedInterruptionSeconds = 0
            currentInterruptionType = type
            currentInterruptionAction = action

            // タイマーが停止している場合は自動的に開始
            if !isRunning {
                start()
            }
        }
    }

    /// 中断モードを終了
    public func endInterruptionMode() {
        if isInterruptionMode {
            // 介入終了 - 記録を保存してタスク作成通知を送信
            if let startTime = interruptionStartTime {
                let endTime = Date()
                // タイマーが停止している場合でも正確な経過時間を計算
                // accumulatedInterruptionSecondsはタイマー実行中のみ更新されるため、
                // startTimeからの実際の経過時間を使用する
                let effectiveDuration = Int(endTime.timeIntervalSince(startTime))

                // 雑務時間がある場合のみ記録を作成
                if effectiveDuration > 0 {
                    let record = InterruptionRecord(
                        startTime: startTime,
                        endTime: endTime,
                        durationSeconds: effectiveDuration,
                        interruptionType: currentInterruptionType,
                        selectedAction: currentInterruptionAction
                    )
                    interruptionRecords.append(record)
                    saveInterruptionRecords()

                    // タスク作成通知を送信
                    NotificationCenter.default.post(
                        name: .interruptionEnded,
                        object: nil,
                        userInfo: [
                            "startTime": startTime,
                            "endTime": endTime,
                            "durationSeconds": effectiveDuration,
                            "interruptionType": currentInterruptionType ?? "",
                            "selectedAction": currentInterruptionAction ?? "",
                        ]
                    )
                }
            }

            isInterruptionMode = false
            interruptionStartTime = nil
            accumulatedInterruptionSeconds = 0
            currentInterruptionType = nil
            currentInterruptionAction = nil

            // 介入モード終了後、作業フェーズでタスクがある場合は作業時刻を再開
            if isRunning && currentPhase == .work && currentTask != nil {
                taskStartTime = Date()
                taskPausedDuration = 0
            }
        }
    }

    /// 雑務・介入モードをトグルする（後方互換性のため残す）
    public func toggleInterruptionMode() {
        if isInterruptionMode {
            endInterruptionMode()
        } else {
            // デフォルトの雑務モードとして開始
            startInterruptionMode(type: "雑務", action: nil)
        }
    }

    /// 介入記録を保存
    private func saveInterruptionRecords() {
        if let encoded = try? JSONEncoder().encode(interruptionRecords) {
            UserDefaults.standard.set(encoded, forKey: "pomodoro_interruption_records")
        }
    }

    /// 介入記録を読み込み
    private func loadInterruptionRecords() {
        if let data = UserDefaults.standard.data(forKey: "pomodoro_interruption_records"),
            let records = try? JSONDecoder().decode([InterruptionRecord].self, from: data)
        {
            interruptionRecords = records
        }
    }

    /// 介入記録をクリア
    public func clearInterruptionRecords() {
        interruptionRecords.removeAll()
        saveInterruptionRecords()
    }

    public func getElapsedPomodoros() -> Double {
        if currentPhase == .work, let taskId = currentTask?.id {
            // 現在のタスクの累積実作業時間を取得
            let totalWorkSeconds = accumulatedWorkSecondsByTask[taskId] ?? 0

            // 0.01ポモドーロ単位で計算
            let elapsedSeconds = Double(totalWorkSeconds)
            let hundredthPomodoroSeconds = Double(workDuration) / 100.0
            let completedHundredths = floor(elapsedSeconds / hundredthPomodoroSeconds)
            return completedHundredths * 0.01
        } else {
            return 0.0
        }
    }

    deinit {
        timer?.invalidate()
        audioPlayer?.stop()
        audioPlayer = nil
    }
}

extension Notification.Name {
    static let taskUpdated = Notification.Name("taskUpdated")
    static let interruptionEnded = Notification.Name("interruptionEnded")
    static let pomodoroProgressByTaskId = Notification.Name("pomodoroProgressByTaskId")
}

extension String {
    var expandingTildeInPath: String {
        return NSString(string: self).expandingTildeInPath
    }
}
