import SwiftUI

struct FocusedMainView: View {
    @ObservedObject var timer: PomodoroTimer
    @ObservedObject var taskListVM: TaskListViewModel
    @State private var newTaskText = ""
    @State private var showSettings = false
    @State private var showClearCompletedConfirm = false
    @State private var showClearAllConfirm = false
    @State private var dropTargetId: String?  // サブタスク化用
    @State private var insertBeforeId: String?  // 割り込み挿入用
    @State private var activePriority: Priority = .medium  // 現在ハイライト中の優先度
    @State private var pressedButton: String?  // 押下中のボタンID
    @State private var toastMessage: String?  // トースト通知
    @State private var showQuickCapture: Bool = false  // Quick Capture シート
    @State private var quickCaptureText: String = ""
    @State private var pendingCompleteTaskId: String?  // サブタスク確認待ちの親タスクID
    @State private var pendingCompleteSubtaskCount: Int = 0
    @State private var showCompleteWithSubtasksConfirm: Bool = false
    @State private var pendingDeleteTaskId: String?  // サブタスクごと削除する確認待ちのタスクID
    @State private var pendingDeleteSubtaskCount: Int = 0
    @State private var showDeleteWithSubtasksConfirm: Bool = false
    @AppStorage("sortState") private var sortState: SortState = .unsorted  // ソート状態
    @AppStorage("isTopmost") private var isTopmost: Bool = false  // 最前面固定
    @AppStorage("viewMode") private var viewMode: ViewMode = .separated  // 表示モード
    @AppStorage("timerPreset") private var timerPreset: TimerPreset = .shortFocus  // タイマープリセット
    @AppStorage("strictBreakMode") private var strictBreakMode: Bool = false  // 厳格な休憩モード
    @StateObject private var breakLockController = BreakLockWindowController()
    // タイマープリセット設定（カスタマイズ可能）
    @AppStorage("shortFocusWork") private var shortFocusWork: Int = 12
    @AppStorage("shortFocusBreak") private var shortFocusBreak: Int = 3
    @AppStorage("shortFocusLongBreak") private var shortFocusLongBreak: Int = 15
    @AppStorage("deepFocusWork") private var deepFocusWork: Int = 35
    @AppStorage("deepFocusBreak") private var deepFocusBreak: Int = 10
    @AppStorage("deepFocusLongBreak") private var deepFocusLongBreak: Int = 30
    @FocusState private var isInputFocused: Bool

    enum SortState: String {
        case unsorted  // 灰色
        case descending  // 赤（高→低）
        case ascending  // 青（低→高）
    }

    enum ViewMode: String {
        case separated   // 分離ビュー（未完了/完了で分ける）
        case hierarchy   // 階層ビュー（階層を維持）
    }

    enum TimerPreset: String {
        case shortFocus  // 12-3-15 (Short Focus Mode)
        case deepFocus   // 35-10-30 (Deep Focus Mode)

        var settings: (work: Int, shortBreak: Int, longBreak: Int) {
            switch self {
            case .shortFocus: return (12, 3, 15)
            case .deepFocus: return (35, 10, 30)
            }
        }
    }

    var body: some View {
        standardLayout
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 440, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .animation(.easeInOut(duration: 0.25), value: timer.currentPhase)
        .onAppear {
            isInputFocused = true
            updateTimerTask()
            applyWindowLevel()
            updateBreakLock()
        }
        .onChange(of: taskListVM.currentTask?.id) { _, _ in
            updateTimerTask()
        }
        .onChange(of: taskListVM.taskList.tasks) { _, _ in
            updateTimerTask()
        }
        .onChange(of: timer.currentPhase) { _, _ in
            applyWindowLevel()
            updateBreakLock()
        }
        .onChange(of: strictBreakMode) { _, _ in
            applyWindowLevel()
            updateBreakLock()
        }
        .onChange(of: showSettings) { _, _ in
            // シートを閉じたら保留していたロックを適用する
            updateBreakLock()
        }
        .onChange(of: showQuickCapture) { _, _ in
            updateBreakLock()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(timer: timer)
        }
        .sheet(isPresented: $showQuickCapture) {
            QuickCaptureView(
                text: $quickCaptureText,
                onSave: {
                    taskListVM.quickCapture(quickCaptureText)
                    quickCaptureText = ""
                    showQuickCapture = false
                    showToast(String(localized: "toast.captured"))
                },
                onCancel: {
                    quickCaptureText = ""
                    showQuickCapture = false
                }
            )
        }
        .alert(String(localized: "alert.clearCompleted.title"), isPresented: $showClearCompletedConfirm) {
            Button(String(localized: "button.cancel"), role: .cancel) {}
            Button(String(localized: "button.delete"), role: .destructive) {
                taskListVM.clearCompleted()
                showToast(String(localized: "toast.clearedCompleted"))
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(String(localized: "alert.clearCompleted.message"))
        }
        .alert(String(localized: "alert.clearAll.title"), isPresented: $showClearAllConfirm) {
            Button(String(localized: "button.cancel"), role: .cancel) {}
            Button(String(localized: "button.delete"), role: .destructive) {
                taskListVM.clearAll()
                showToast(String(localized: "toast.clearedAll"))
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(String(localized: "alert.clearAll.message"))
        }
        .alert(
            String(localized: "alert.completeWithSubtasks.title"),
            isPresented: $showCompleteWithSubtasksConfirm
        ) {
            Button(String(localized: "button.cancel"), role: .cancel) {
                pendingCompleteTaskId = nil
                pendingCompleteSubtaskCount = 0
            }
            Button(String(localized: "button.completeAll")) {
                if let id = pendingCompleteTaskId {
                    performComplete(taskId: id)
                }
                pendingCompleteTaskId = nil
                pendingCompleteSubtaskCount = 0
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(String(localized: "alert.completeWithSubtasks.message \(pendingCompleteSubtaskCount)"))
        }
        .alert(
            String(localized: "alert.deleteWithSubtasks.title"),
            isPresented: $showDeleteWithSubtasksConfirm
        ) {
            Button(String(localized: "button.cancel"), role: .cancel) {
                pendingDeleteTaskId = nil
                pendingDeleteSubtaskCount = 0
            }
            Button(String(localized: "button.delete"), role: .destructive) {
                if let id = pendingDeleteTaskId {
                    taskListVM.deleteTask(id: id)
                }
                pendingDeleteTaskId = nil
                pendingDeleteSubtaskCount = 0
            }
        } message: {
            Text(String(localized: "alert.deleteWithSubtasks.message \(pendingDeleteSubtaskCount)"))
        }
        .overlay(alignment: .top) {
            if let message = toastMessage {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .shadow(radius: 4)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastMessage)
    }

    // MARK: - Layouts

    private var standardLayout: some View {
        VStack(spacing: 0) {
            inputSection
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            if let currentTask = taskListVM.currentTask {
                currentTaskSection(currentTask)
            } else {
                emptyStateView
            }

            Divider()

            taskListSection

            Divider()

            footerSection
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    /// 現フェーズの進捗 (0...1) - 標準モードのリングが使う
    private var phaseProgress: Double {
        let total: Int
        switch timer.currentPhase {
        case .work: total = timer.workDuration
        case .break_: total = timer.breakDuration
        case .longBreak: total = timer.longBreakDuration
        }
        guard total > 0 else { return 0 }
        return 1.0 - (Double(timer.remainingSeconds) / Double(total))
    }

    // MARK: - Mode Toggles & Break Lock

    private func toggleMinimal() {
        // AppDelegate (single source of truth) に委譲
        TomadoAppDelegate.shared?.toggleMinimalMode()
    }

    /// 厳格な休憩モード中は強制 topmost、それ以外はユーザー設定に従う
    private func applyWindowLevel() {
        guard let window = TomadoAppDelegate.shared?.mainWindow else { return }
        let inBreak = timer.currentPhase != .work
        if strictBreakMode && inBreak {
            window.level = .floating
        } else {
            window.level = isTopmost ? .floating : .normal
        }
    }

    /// 休憩フェーズに合わせてフルスクリーンロックウィンドウを表示/非表示
    private func updateBreakLock() {
        let inBreak = timer.currentPhase != .work
        guard strictBreakMode && inBreak else {
            breakLockController.hide()
            return
        }
        // シート表示中にロックを被せるとシートごと閉じ込めてしまうので、閉じるまで待つ
        guard !showSettings && !showQuickCapture else { return }
        breakLockController.show(timer: timer, onSkip: {
            showToast(String(localized: "toast.skipped"))
        })
    }

    // MARK: - Input Section

    private var inputSection: some View {
        HStack(spacing: 8) {
            TextField(String(localized: "input.placeholder"), text: $newTaskText)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isInputFocused)
                .onSubmit {
                    // デフォルトはEnterで中優先度
                    addTask(priority: .medium)
                }
                .onKeyPress(.return, phases: .down) { event in
                    guard !newTaskText.isEmpty else { return .ignored }
                    // Shift+Enter = 低, Cmd+Enter = 高
                    if event.modifiers.contains(.shift) {
                        addTask(priority: .low)
                        return .handled
                    } else if event.modifiers.contains(.command) {
                        addTask(priority: .high)
                        return .handled
                    }
                    return .ignored  // 通常のEnterはonSubmitで処理
                }

            // 優先度ボタン
            ModifierKeyAwarePriorityButtons(
                activePriority: $activePriority,
                onAdd: { priority in addTask(priority: priority) },
                isDisabled: newTaskText.isEmpty,
                colorFor: colorFor
            )
        }
    }

    private func addTask(priority: Priority) {
        guard !newTaskText.isEmpty else { return }
        taskListVM.addTask(title: newTaskText, priority: priority)
        newTaskText = ""
        sortState = .unsorted  // 手動追加でソート状態リセット
    }

    // MARK: - Current Task Section

    private func currentTaskSection(_ task: TodoTask) -> some View {
        VStack(spacing: 10) {
            Spacer()

            // タスク名 + 優先度
            HStack(spacing: 6) {
                Text(task.priority.symbol)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(colorFor(task.priority))
                Text(task.title)
                    .font(.system(size: 16, weight: .medium))
            }
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 20)

            // タイマー
            timerDisplay

            // コントロール
            controlButtons(task)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var timerDisplay: some View {
        VStack(spacing: 6) {
            Text(formatTime(timer.remainingSeconds))
                .font(.system(size: 52, weight: .ultraLight, design: .monospaced))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundColor(timer.isRunning ? .primary : .primary.opacity(0.55))
                .contentShape(Rectangle())
                .onTapGesture { toggleTimer() }

            Text(phaseText)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(phaseColor)
                .textCase(.uppercase)
                .tracking(1.2)

            // 横棒プログレスバー
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 2)
                    Capsule()
                        .fill(phaseColor.opacity(0.7))
                        .frame(width: geo.size.width * phaseProgress, height: 2)
                        .animation(.linear(duration: 0.5), value: phaseProgress)
                }
            }
            .frame(height: 2)
            .frame(maxWidth: 180)
            .padding(.top, 2)
        }
    }

    private func controlButtons(_ task: TodoTask) -> some View {
        HStack(spacing: 16) {
            // 後回しボタン
            controlButton(
                id: "postpone",
                icon: "arrow.uturn.down.circle",
                color: .orange,
                action: postponeCurrentTask
            )
            .keyboardShortcut("l", modifiers: .command)

            // 完了ボタン
            controlButton(
                id: "complete",
                icon: "checkmark.circle",
                color: .green,
                action: completeCurrentTask
            )
            .keyboardShortcut("d", modifiers: .command)

            // 再生/停止ボタン
            controlButton(
                id: "play",
                icon: timer.isRunning ? "pause.circle.fill" : "play.circle.fill",
                color: phaseColor,
                size: 44,
                action: toggleTimer
            )
            .keyboardShortcut("p", modifiers: .command)

            // スキップボタン
            controlButton(
                id: "skip",
                icon: "forward.circle",
                color: .secondary,
                action: {
                    timer.skip()
                    showToast(String(localized: "toast.skipped"))
                }
            )
            .keyboardShortcut("s", modifiers: .command)

            // リセットボタン
            controlButton(
                id: "reset",
                icon: "arrow.counterclockwise.circle",
                color: .secondary,
                action: {
                    timer.resetCycle()
                    showToast(String(localized: "toast.reset"))
                }
            )
            .keyboardShortcut("r", modifiers: .command)
        }
        .frame(maxWidth: .infinity)
    }

    private func controlButton(
        id: String,
        icon: String,
        color: Color,
        size: CGFloat = 22,
        action: @escaping () -> Void
    ) -> some View {
        let isPressed = pressedButton == id
        return Button(action: {
            flashButton(id)
            action()
        }) {
            Image(systemName: icon)
                .font(.system(size: size))
        }
        .buttonStyle(.plain)
        .foregroundColor(color)
        .scaleEffect(isPressed ? 1.2 : 1.0)
        .animation(.easeOut(duration: 0.1), value: isPressed)
    }

    private func flashButton(_ id: String) {
        pressedButton = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pressedButton = nil
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }

    private func sortButton() -> some View {
        let isPressed = pressedButton == "sort"
        let (icon, color): (String, Color) = switch sortState {
        case .unsorted: ("arrow.up.arrow.down", .secondary)
        case .descending: ("arrow.down", .red)
        case .ascending: ("arrow.up", .blue)
        }

        return Button(action: {
            flashButton("sort")
            toggleSort()
        }) {
            Image(systemName: icon)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundColor(color)
        .scaleEffect(isPressed ? 1.3 : 1.0)
        .animation(.easeOut(duration: 0.1), value: isPressed)
    }

    private func toggleSort() {
        switch sortState {
        case .unsorted:
            taskListVM.sort(ascending: false)
            sortState = .descending
            showToast(String(localized: "toast.sortDescending"))
        case .descending:
            taskListVM.sort(ascending: true)
            sortState = .ascending
            showToast(String(localized: "toast.sortAscending"))
        case .ascending:
            // unsortedに戻る（ソート前に控えた手動順序を復元する）
            taskListVM.restoreManualOrder()
            sortState = .unsorted
            showToast(String(localized: "toast.sortUnsorted"))
        }
    }

    private func resetSortState() {
        sortState = .unsorted
    }

    private func viewModeButton() -> some View {
        let isPressed = pressedButton == "viewMode"
        let (icon, color): (String, Color) = switch viewMode {
        case .separated: ("rectangle.split.2x1", .secondary)
        case .hierarchy: ("list.bullet.indent", .accentColor)
        }

        return Button(action: {
            flashButton("viewMode")
            toggleViewMode()
        }) {
            Image(systemName: icon)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundColor(color)
        .scaleEffect(isPressed ? 1.3 : 1.0)
        .animation(.easeOut(duration: 0.1), value: isPressed)
    }

    private func toggleViewMode() {
        switch viewMode {
        case .separated:
            viewMode = .hierarchy
            showToast(String(localized: "toast.viewHierarchy"))
        case .hierarchy:
            viewMode = .separated
            showToast(String(localized: "toast.viewSeparated"))
        }
    }

    private func timerPresetButton() -> some View {
        let isPressed = pressedButton == "timerPreset"
        let (icon, color): (String, Color) = switch timerPreset {
        case .shortFocus: ("hare", .orange)
        case .deepFocus: ("tortoise", .purple)
        }

        return Button(action: {
            flashButton("timerPreset")
            toggleTimerPreset()
        }) {
            Image(systemName: icon)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundColor(color)
        .scaleEffect(isPressed ? 1.3 : 1.0)
        .animation(.easeOut(duration: 0.1), value: isPressed)
        .help(String(localized: "tooltip.timerPreset"))
    }

    private func toggleTimerPreset() {
        switch timerPreset {
        case .shortFocus:
            timerPreset = .deepFocus
            timer.updateSettings(
                workMinutes: deepFocusWork,
                breakMinutes: deepFocusBreak,
                longBreakMinutes: deepFocusLongBreak,
                pomodorosUntilLongBreak: timer.pomodorosUntilLongBreak
            )
            showToast(String(localized: "toast.deepFocus"))
        case .deepFocus:
            timerPreset = .shortFocus
            timer.updateSettings(
                workMinutes: shortFocusWork,
                breakMinutes: shortFocusBreak,
                longBreakMinutes: shortFocusLongBreak,
                pomodorosUntilLongBreak: timer.pomodorosUntilLongBreak
            )
            showToast(String(localized: "toast.shortFocus"))
        }
    }

    private func topmostButton() -> some View {
        let isPressed = pressedButton == "topmost"

        return Button(action: {
            flashButton("topmost")
            toggleTopmost()
        }) {
            Image(systemName: isTopmost ? "pin.fill" : "pin")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundColor(isTopmost ? .accentColor : .secondary)
        .scaleEffect(isPressed ? 1.3 : 1.0)
        .animation(.easeOut(duration: 0.1), value: isPressed)
    }

    private func toggleTopmost() {
        isTopmost.toggle()
        applyWindowLevel()
        showToast(isTopmost ? String(localized: "toast.topmostOn") : String(localized: "toast.topmostOff"))
    }

    private func minimalToggleButton() -> some View {
        // このボタンは standard layout のフッターにしか存在しない（minimal 時はメインが隠れる）
        // ので、アイコンは常に「縮小 (compress)」固定で正しい
        let isPressed = pressedButton == "minimal"
        return Button(action: {
            flashButton("minimal")
            toggleMinimal()
        }) {
            Image(systemName: "rectangle.compress.vertical")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .scaleEffect(isPressed ? 1.3 : 1.0)
        .animation(.easeOut(duration: 0.1), value: isPressed)
    }

    private func footerButton(
        id: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        let isPressed = pressedButton == id
        return Button(action: {
            flashButton(id)
            action()
        }) {
            Image(systemName: icon)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .scaleEffect(isPressed ? 1.3 : 1.0)
        .animation(.easeOut(duration: 0.1), value: isPressed)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36))
                .foregroundColor(.green.opacity(0.5))
            Text(String(localized: "empty.title"))
                .font(.headline)
                .foregroundColor(.secondary)
            Text(String(localized: "empty.message"))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // タスクが無くてもタイマーは操作できる（休憩を最後まで走らせられる）
            timerDisplay
            taskFreeControlButtons

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    /// タスクが無いときのタイマー操作（再生・スキップ・リセットのみ）
    private var taskFreeControlButtons: some View {
        HStack(spacing: 16) {
            controlButton(
                id: "play",
                icon: timer.isRunning ? "pause.circle.fill" : "play.circle.fill",
                color: phaseColor,
                size: 36,
                action: toggleTimer
            )
            .keyboardShortcut("p", modifiers: .command)

            controlButton(
                id: "skip",
                icon: "forward.circle",
                color: .secondary,
                action: {
                    timer.skip()
                    showToast(String(localized: "toast.skipped"))
                }
            )
            .keyboardShortcut("s", modifiers: .command)

            controlButton(
                id: "reset",
                icon: "arrow.counterclockwise.circle",
                color: .secondary,
                action: {
                    timer.resetCycle()
                    showToast(String(localized: "toast.reset"))
                }
            )
            .keyboardShortcut("r", modifiers: .command)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Task List Section

    private var taskListSection: some View {
        Group {
            switch viewMode {
            case .separated:
                separatedTaskListView
            case .hierarchy:
                hierarchyTaskListView
            }
        }
    }

    /// 分離ビュー：未完了タスク → 完了タスク
    private var separatedTaskListView: some View {
        Group {
            let hierarchyTasks = taskListVM.tasksInHierarchyOrder()
            let completedTasks = taskListVM.taskList.tasks.filter { $0.isCompleted }
            let currentTaskId = taskListVM.currentTask?.id
            let ancestorIds = currentTaskId.map { taskListVM.getAncestorIds(for: $0) } ?? []

            if !hierarchyTasks.isEmpty || !completedTasks.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // 階層順でタスクを表示（親→子）
                        ForEach(Array(hierarchyTasks.enumerated()), id: \.element.id) { _, task in
                            let isCurrent = task.id == currentTaskId
                            let ancestorIndex = ancestorIds.firstIndex(of: task.id)

                            VStack(spacing: 0) {
                                // 挿入ライン（ドロップターゲット）
                                insertLine(before: task)

                                // タスク行
                                taskRow(task, isCurrent: isCurrent, ancestorIndex: ancestorIndex)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(taskRowBackground(task, isCurrent: isCurrent, ancestorIndex: ancestorIndex))
                            }
                        }

                        // 末尾ドロップゾーン（下端に落とすとルート化して最後尾へ）
                        if !hierarchyTasks.isEmpty {
                            trailingDropZone()
                        }

                        // 完了タスク
                        if !completedTasks.isEmpty {
                            Divider().padding(.vertical, 8)
                            ForEach(completedTasks, id: \.id) { task in
                                completedTaskRow(task)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .id("completed-\(task.id)")
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Color.clear.frame(height: 100)
            }
        }
    }

    /// 階層ビュー：完了/未完了を混合して階層を維持
    private var hierarchyTaskListView: some View {
        Group {
            let allTasksInHierarchy = taskListVM.allTasksInHierarchyOrder()
            let currentTaskId = taskListVM.currentTask?.id
            let ancestorIds = currentTaskId.map { taskListVM.getAncestorIds(for: $0) } ?? []

            if !allTasksInHierarchy.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(allTasksInHierarchy.enumerated()), id: \.element.id) { _, task in
                            let isCurrent = task.id == currentTaskId
                            let ancestorIndex = ancestorIds.firstIndex(of: task.id)

                            VStack(spacing: 0) {
                                if !task.isCompleted {
                                    insertLine(before: task)
                                }

                                if task.isCompleted {
                                    // 完了タスク（階層ビュー用：インデント維持）
                                    hierarchyCompletedTaskRow(task)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 4)
                                        .id("hierarchy-\(task.id)")
                                } else {
                                    // 未完了タスク
                                    taskRow(task, isCurrent: isCurrent, ancestorIndex: ancestorIndex)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(taskRowBackground(task, isCurrent: isCurrent, ancestorIndex: ancestorIndex))
                                }
                            }
                        }

                        // 末尾ドロップゾーン（下端に落とすとルート化して最後尾へ）
                        if allTasksInHierarchy.contains(where: { !$0.isCompleted }) {
                            trailingDropZone()
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Color.clear.frame(height: 100)
            }
        }
    }

    /// 階層ビュー用の完了タスク行（インデント維持、打ち消し線）
    private func hierarchyCompletedTaskRow(_ task: TodoTask) -> some View {
        HStack(spacing: 4) {
            // インデント
            if task.indentLevel > 0 {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: CGFloat(task.indentLevel * 16))
            }

            Image(systemName: "checkmark")
                .font(.caption)
                .foregroundColor(.green.opacity(0.6))

            Text(task.title)
                .font(.body)
                .strikethrough()
                .foregroundColor(.secondary.opacity(0.5))
                .lineLimit(1)

            Spacer()

            if task.pomodoros > 0 {
                Text("\(task.pomodoros)×")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.55))
            }
        }
        .contextMenu {
            Button(String(localized: "button.uncomplete")) {
                taskListVM.uncompleteTask(id: task.id)
            }
            Button(String(localized: "button.delete"), role: .destructive) {
                requestDelete(taskId: task.id)
            }
        }
    }

    /// 挿入ライン（D&Dで割り込み挿入用）
    /// ドロップしたタスクは対象と同じ階層に揃うので、ルートの前に落とせばサブタスクは
    /// そのままルートへ引き上がる（＝D&Dだけで階層を上げ下げできる）
    private func insertLine(before task: TodoTask) -> some View {
        let isTargeted = insertBeforeId == task.id
        return Rectangle()
            .fill(isTargeted ? Color.accentColor : Color.clear)
            .frame(height: isTargeted ? 3 : 1)
            .contentShape(Rectangle().size(width: .infinity, height: 12))  // タッチ領域は広めに
            .dropDestination(for: String.self) { droppedIds, _ in
                guard let droppedId = droppedIds.first, droppedId != task.id else { return false }
                taskListVM.moveTask(droppedId, before: task.id, newParentId: task.parentId)
                sortState = .unsorted
                return true
            } isTargeted: { targeted in
                insertBeforeId = targeted ? task.id : nil
            }
    }

    /// リスト末尾のドロップゾーン（下端に落とす = ルート化して末尾へ）
    private func trailingDropZone() -> some View {
        let isTargeted = insertBeforeId == Self.trailingDropId
        return Rectangle()
            .fill(isTargeted ? Color.accentColor : Color.clear)
            .frame(height: isTargeted ? 3 : 1)
            .contentShape(Rectangle().size(width: .infinity, height: 28))
            .dropDestination(for: String.self) { droppedIds, _ in
                guard let droppedId = droppedIds.first else { return false }
                taskListVM.moveTaskToEndAsRoot(droppedId)
                sortState = .unsorted
                return true
            } isTargeted: { targeted in
                insertBeforeId = targeted ? Self.trailingDropId : nil
            }
    }

    /// 末尾ドロップゾーンのハイライト用センチネル（実タスクIDと衝突しない）
    private static let trailingDropId = "__tomado.trailingDropZone__"

    /// タスク行の背景色を決定
    private func taskRowBackground(_ task: TodoTask, isCurrent: Bool, ancestorIndex: Int?) -> Color {
        if dropTargetId == task.id {
            return Color.accentColor.opacity(0.2)
        }
        if isCurrent {
            return phaseColor.opacity(0.15)
        }
        if let index = ancestorIndex {
            // 祖先の濃さ：近い親ほど濃い（index 0 = 直近の親）
            let opacity = 0.12 - Double(index) * 0.03
            return phaseColor.opacity(max(opacity, 0.03))
        }
        return Color.clear
    }

    private func taskRow(_ task: TodoTask, isCurrent: Bool = false, ancestorIndex: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // プレイマーク（現在のタスク）
                if isCurrent {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundColor(phaseColor)
                }

                // インデント
                if task.indentLevel > 0 {
                    HStack(spacing: 0) {
                        ForEach(0..<task.indentLevel, id: \.self) { level in
                            Rectangle()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(width: 2, height: 16)
                                .padding(.horizontal, 6)
                        }
                    }
                }

                // タスク名 + ノートマーカー
                Text(task.title)
                    .font(task.isRoot ? .body : .callout)
                    .foregroundColor(task.isRoot || isCurrent ? .primary : .secondary)
                    .fontWeight(isCurrent ? .medium : .regular)
                    .lineLimit(1)

                if task.notes != nil {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary.opacity(0.5))
                }

                Spacer()

                if task.pomodoros > 0 {
                    Text("\(task.pomodoros)×")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.55))
                }

                // サブタスク解除ボタン
                if !task.isRoot {
                    Button(action: {
                        taskListVM.makeRootTask(taskId: task.id)
                        sortState = .unsorted
                    }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // ルートタスク：優先度セレクタ（右端）
                if task.isRoot {
                    prioritySelector(for: task)
                }
            }

            // ノート: タスク名の下に薄く 1 行表示（ホバーで全文ツールチップ）
            if let notes = task.notes, !notes.isEmpty {
                let firstLine = notes.components(separatedBy: "\n").first ?? notes
                let prefix = task.indentLevel > 0
                    ? String(repeating: "  ", count: task.indentLevel) + (isCurrent ? "  " : "")
                    : (isCurrent ? "  " : "")
                Text(prefix + firstLine)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
                    .lineLimit(1)
                    .help(notes)
                    .padding(.leading, 0)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // タップでそのタスクを選択（再生開始）
            taskListVM.selectTask(id: task.id)
        }
        .draggable(task.id) {
            Text(task.title)
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
        }
        .dropDestination(for: String.self) { droppedIds, _ in
            guard let droppedId = droppedIds.first,
                  droppedId != task.id else { return false }
            // タスク上にドロップ → サブタスク化
            taskListVM.makeSubtask(taskId: droppedId, parentId: task.id)
            sortState = .unsorted
            return true
        } isTargeted: { isTargeted in
            dropTargetId = isTargeted ? task.id : nil
        }
        .contextMenu {
            if !task.isRoot {
                Button(String(localized: "button.makeIndependent")) {
                    taskListVM.makeRootTask(taskId: task.id)
                    sortState = .unsorted
                }
                Divider()
            }
            Button(String(localized: "button.delete"), role: .destructive) { requestDelete(taskId: task.id) }
        }
    }

    /// 優先度セレクタ（3つの独立ボタン）
    private func prioritySelector(for task: TodoTask) -> some View {
        HStack(spacing: 2) {
            ForEach([Priority.low, .medium, .high], id: \.self) { priority in
                Button(action: { setPriority(task, priority) }) {
                    Text(priority.symbol)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(task.priority == priority ? colorFor(priority) : .secondary.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 優先度を設定（表示順は変えない）
    private func setPriority(_ task: TodoTask, _ priority: Priority) {
        taskListVM.setPriority(priority, forTaskId: task.id)
    }

    private func completedTaskRow(_ task: TodoTask) -> some View {
        // 祖先のタイトルと完了状態を取得（ルートから順に）
        let ancestorInfo: [(title: String, isCompleted: Bool)] = {
            let ancestorIds = taskListVM.getAncestorIds(for: task.id) // 近い順
            var info: [(String, Bool)] = []
            for ancestorId in ancestorIds.reversed() { // ルートから順に
                if let ancestor = taskListVM.taskList.tasks.first(where: { $0.id == ancestorId }) {
                    info.append((ancestor.title, ancestor.isCompleted))
                }
            }
            return info
        }()

        // 未完了の祖先が1つでもいれば、祖先チェーンを表示
        let hasIncompleteAncestor = ancestorInfo.contains { !$0.isCompleted }

        // 全ての祖先が完了している場合はインデント表示
        let showIndent = task.indentLevel > 0 && !hasIncompleteAncestor

        return HStack(spacing: 4) {
            // インデント（全祖先が完了している場合）
            if showIndent {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: CGFloat(task.indentLevel * 16))
            }

            Image(systemName: "checkmark")
                .font(.caption)
                .foregroundColor(.green)

            // 未完了の祖先がある場合：全祖先を表示（完了済み祖先は打ち消し線）
            if hasIncompleteAncestor {
                ForEach(Array(ancestorInfo.enumerated()), id: \.offset) { _, info in
                    Text(info.title)
                        .font(.body)
                        .strikethrough(info.isCompleted)
                        .foregroundColor(.secondary.opacity(info.isCompleted ? 0.4 : 0.6))
                        .lineLimit(1)
                    Text(">")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.4))
                }
            }

            Text(task.title)
                .font(.body)
                .strikethrough()
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()

            if task.pomodoros > 0 {
                Text("\(task.pomodoros)×")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.55))
            }
        }
        .contextMenu {
            Button(String(localized: "button.uncomplete")) {
                taskListVM.uncompleteTask(id: task.id)
            }
            Button(String(localized: "button.delete"), role: .destructive) {
                requestDelete(taskId: task.id)
            }
        }
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        HStack(spacing: 10) {
            let stats = taskListVM.taskList.stats
            Text("\(stats.completed)/\(stats.total)")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.6))
                .layoutPriority(1)
                .fixedSize()

            Spacer()

            // 視覚状態が重要な toggle 類だけ常時表示
            timerPresetButton()
                .keyboardShortcut("t", modifiers: [.command, .shift])
            viewModeButton()
                .keyboardShortcut("v", modifiers: [.command, .shift])
            sortButton()
                .disabled(taskListVM.taskList.tasks.isEmpty)
                .keyboardShortcut("s", modifiers: [.command, .shift])
            minimalToggleButton()
                .keyboardShortcut("m", modifiers: [.command, .shift])

            // overflow メニュー（ピン・キャプチャ・I/O・破壊系）
            moreMenuButton

            // 設定（常時アクセス可能性を保つ）
            footerButton(id: "settings", icon: "gear") {
                showSettings = true
            }

            // 非表示のキーボードショートカット担保
            hiddenFooterShortcuts
        }
    }

    /// overflow メニュー: ピン留め・I/O・破壊系をまとめる
    private var moreMenuButton: some View {
        Menu {
            Button {
                toggleTopmost()
            } label: {
                Label(
                    isTopmost ? String(localized: "menu.unpin") : String(localized: "menu.pin"),
                    systemImage: isTopmost ? "pin.slash" : "pin"
                )
            }

            Divider()

            Button {
                showQuickCapture = true
            } label: {
                Label(String(localized: "menu.quickCapture"), systemImage: "square.and.pencil")
            }
            Button {
                let count = taskListVM.importFromClipboard()
                if count > 0 {
                    if sortState != .unsorted {
                        taskListVM.sort(ascending: sortState == .ascending)
                    }
                    showToast(String(localized: "toast.imported \(count)"))
                }
            } label: {
                Label(String(localized: "menu.import"), systemImage: "square.and.arrow.down")
            }
            Button {
                taskListVM.exportToClipboard()
                showToast(String(localized: "toast.exported"))
            } label: {
                Label(String(localized: "menu.export"), systemImage: "square.and.arrow.up")
            }
            .disabled(taskListVM.taskList.tasks.isEmpty)

            Divider()

            Button(role: .destructive) {
                showClearCompletedConfirm = true
            } label: {
                Label(String(localized: "menu.clearCompleted"), systemImage: "checkmark.circle.badge.xmark")
            }
            .disabled(taskListVM.taskList.tasks.filter { $0.isCompleted }.isEmpty)

            Button(role: .destructive) {
                showClearAllConfirm = true
            } label: {
                Label(String(localized: "menu.clearAll"), systemImage: "trash")
            }
            .disabled(taskListVM.taskList.tasks.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 24)
    }

    /// メニュー化したものでもキーボードショートカットは生かす
    private var hiddenFooterShortcuts: some View {
        Group {
            Button("") { toggleTopmost() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("") { showQuickCapture = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("") {
                let count = taskListVM.importFromClipboard()
                if count > 0 {
                    if sortState != .unsorted {
                        taskListVM.sort(ascending: sortState == .ascending)
                    }
                    showToast(String(localized: "toast.imported \(count)"))
                }
            }
            // ⌘V / ⌘C は OS の貼り付け・コピーに譲る（入力欄にペーストできなくなるため）
            .keyboardShortcut("v", modifiers: [.command, .option])
            Button("") {
                taskListVM.exportToClipboard()
                showToast(String(localized: "toast.exported"))
            }
            .disabled(taskListVM.taskList.tasks.isEmpty)
            .keyboardShortcut("c", modifiers: [.command, .option])
            Button("") { showClearCompletedConfirm = true }
                .disabled(taskListVM.taskList.tasks.filter { $0.isCompleted }.isEmpty)
                .keyboardShortcut(.delete, modifiers: .command)
            Button("") { showClearAllConfirm = true }
                .disabled(taskListVM.taskList.tasks.isEmpty)
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Helpers

    private func toggleTimer() {
        if timer.isRunning {
            timer.pause()
        } else {
            timer.start()
        }
    }

    /// 削除を要求する。サブタスクを巻き添えにする場合だけ確認を挟む
    private func requestDelete(taskId: String) {
        let subtaskCount = taskListVM.subtaskCount(for: taskId)
        if subtaskCount > 0 {
            pendingDeleteTaskId = taskId
            pendingDeleteSubtaskCount = subtaskCount
            showDeleteWithSubtasksConfirm = true
        } else {
            taskListVM.deleteTask(id: taskId)
        }
    }

    private func completeCurrentTask() {
        guard let task = taskListVM.currentTask else { return }
        let count = taskListVM.incompleteSubtaskCount(for: task.id)
        if count > 0 {
            // 未完了サブタスクがある場合は確認モーダル
            pendingCompleteTaskId = task.id
            pendingCompleteSubtaskCount = count
            showCompleteWithSubtasksConfirm = true
        } else {
            performComplete(taskId: task.id)
        }
    }

    /// 実際にタスクを完了 + 親自動完了 + 次タスクへ自動遷移
    private func performComplete(taskId: String) {
        let parentIdBeforeCompletion = taskListVM.taskList.tasks
            .first(where: { $0.id == taskId })?.parentId

        taskListVM.completeTask(id: taskId)
        showToast(String(localized: "toast.completed"))

        // 親タスクの自動完了判定（兄弟が全完了 → 親も自動完了）
        if let parentId = parentIdBeforeCompletion,
           let _ = taskListVM.autoCompleteParentIfReady(for: taskId) {
            // 親も完了したら別途トースト
            showToast(String(localized: "toast.parentAutoCompleted"))
            _ = parentId
        }

        // 次タスクへ自動遷移（集中状態の維持）
        if taskListVM.currentTaskId == nil {
            taskListVM.advanceToNextTask()
        }
    }

    private func postponeCurrentTask() {
        taskListVM.postponeCurrentTask()
        showToast(String(localized: "toast.postponed"))
    }

    private func updateTimerTask() {
        if let task = taskListVM.currentTask {
            timer.setCurrentTask(task)
        } else {
            timer.setCurrentTask(nil)
            // 作業フェーズだけ停止する。休憩にタスクは要らないので走らせたままにする
            if timer.isRunning && timer.currentPhase == .work {
                timer.pause()
            }
        }
    }

    private func formatTime(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private var phaseText: String {
        let cycle = timer.sessionPomodoros + 1
        let total = timer.pomodorosUntilLongBreak
        switch timer.currentPhase {
        case .work: return String(localized: "phase.work \(cycle) \(total)")
        case .break_: return String(localized: "phase.break \(cycle) \(total)")
        case .longBreak: return String(localized: "phase.longBreak")
        }
    }

    private var phaseColor: Color {
        switch timer.currentPhase {
        case .work: return .blue
        case .break_: return .green
        case .longBreak: return .purple
        }
    }

    private func colorFor(_ priority: Priority) -> Color {
        switch priority {
        case .low: return .gray
        case .medium: return .blue
        case .high: return .red
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var timer: PomodoroTimer
    @Environment(\.dismiss) private var dismiss

    @State private var workMinutes: Int
    @State private var breakMinutes: Int
    @State private var longBreakMinutes: Int
    @State private var cycleCount: Int
    @State private var soundEnabled: Bool
    @State private var completionSound: String
    @State private var startSound: String
    @State private var separateStartEndSounds: Bool
    @State private var soundVolume: Double

    // 以下は「保存」を押すまで確定しない下書き（キャンセルで捨てられる）
    @State private var importAllowListFormat: Bool
    @State private var indentStyle: String
    @State private var indentSpaces: Int
    @State private var appLanguage: String
    @State private var shortFocusWork: Int
    @State private var shortFocusBreak: Int
    @State private var shortFocusLongBreak: Int
    @State private var deepFocusWork: Int
    @State private var deepFocusBreak: Int
    @State private var deepFocusLongBreak: Int
    @State private var strictBreakMode: Bool

    /// 現在選択中のプリセット（保存時に、編集されたプリセットの時間をタイマーへ反映するのに使う）
    @AppStorage("timerPreset") private var timerPreset: FocusedMainView.TimerPreset = .shortFocus

    /// 開いたときのプリセット時間。「保存」で本当に編集されたかを判定するのに使う
    @State private var initialPresetMinutes: (work: Int, breakMin: Int, longBreak: Int) = (0, 0, 0)

    private static func storedInt(_ key: String, _ fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? fallback
    }

    init(timer: PomodoroTimer) {
        self.timer = timer
        _workMinutes = State(initialValue: timer.workDuration / 60)
        _breakMinutes = State(initialValue: timer.breakDuration / 60)
        _longBreakMinutes = State(initialValue: timer.longBreakDuration / 60)
        _cycleCount = State(initialValue: timer.pomodorosUntilLongBreak)
        _soundEnabled = State(initialValue: timer.soundEnabled)
        _completionSound = State(initialValue: timer.completionSound)
        _startSound = State(initialValue: timer.startSound)
        _separateStartEndSounds = State(initialValue: timer.separateStartEndSounds)
        _soundVolume = State(initialValue: timer.soundVolume)

        let defaults = UserDefaults.standard
        _importAllowListFormat = State(initialValue: defaults.bool(forKey: "importAllowListFormat"))
        _indentStyle = State(initialValue: defaults.string(forKey: "indentStyle") ?? "spaces")
        _indentSpaces = State(initialValue: Self.storedInt("indentSpaces", 2))
        _appLanguage = State(initialValue: defaults.string(forKey: "appLanguage") ?? "system")
        _shortFocusWork = State(initialValue: Self.storedInt("shortFocusWork", 12))
        _shortFocusBreak = State(initialValue: Self.storedInt("shortFocusBreak", 3))
        _shortFocusLongBreak = State(initialValue: Self.storedInt("shortFocusLongBreak", 15))
        _deepFocusWork = State(initialValue: Self.storedInt("deepFocusWork", 35))
        _deepFocusBreak = State(initialValue: Self.storedInt("deepFocusBreak", 10))
        _deepFocusLongBreak = State(initialValue: Self.storedInt("deepFocusLongBreak", 30))
        _strictBreakMode = State(initialValue: defaults.bool(forKey: "strictBreakMode"))
    }

    /// 下書きを現在値から取り直す。
    /// Settings シーン（⌘,）のビューは一度しか init されず閉じても生き続けるので、
    /// 開くたびにここで読み直さないと古い値で上書き保存してしまう
    private func reloadDrafts() {
        let defaults = UserDefaults.standard
        workMinutes = timer.workDuration / 60
        breakMinutes = timer.breakDuration / 60
        longBreakMinutes = timer.longBreakDuration / 60
        cycleCount = timer.pomodorosUntilLongBreak
        soundEnabled = timer.soundEnabled
        completionSound = timer.completionSound
        startSound = timer.startSound
        separateStartEndSounds = timer.separateStartEndSounds
        soundVolume = timer.soundVolume

        importAllowListFormat = defaults.bool(forKey: "importAllowListFormat")
        indentStyle = defaults.string(forKey: "indentStyle") ?? "spaces"
        indentSpaces = Self.storedInt("indentSpaces", 2)
        appLanguage = defaults.string(forKey: "appLanguage") ?? "system"
        shortFocusWork = Self.storedInt("shortFocusWork", 12)
        shortFocusBreak = Self.storedInt("shortFocusBreak", 3)
        shortFocusLongBreak = Self.storedInt("shortFocusLongBreak", 15)
        deepFocusWork = Self.storedInt("deepFocusWork", 35)
        deepFocusBreak = Self.storedInt("deepFocusBreak", 10)
        deepFocusLongBreak = Self.storedInt("deepFocusLongBreak", 30)
        strictBreakMode = defaults.bool(forKey: "strictBreakMode")

        initialPresetMinutes = activePresetMinutes
    }

    /// 現在選択中のプリセットの下書き値
    private var activePresetMinutes: (work: Int, breakMin: Int, longBreak: Int) {
        switch timerPreset {
        case .shortFocus: (shortFocusWork, shortFocusBreak, shortFocusLongBreak)
        case .deepFocus: (deepFocusWork, deepFocusBreak, deepFocusLongBreak)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(String(localized: "settings.title"))
                .font(.headline)

            Form {
                Section(String(localized: "settings.shortcuts")) {
                    Text(String(localized: "settings.shortcuts.row1"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text(String(localized: "settings.shortcuts.row2"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text(String(localized: "settings.shortcuts.row3"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text(String(localized: "settings.shortcuts.row4"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Section("🐇 " + String(localized: "settings.shortFocus")) {
                    Stepper(String(localized: "settings.work \(shortFocusWork)"), value: $shortFocusWork, in: 1...60)
                    Stepper(String(localized: "settings.break \(shortFocusBreak)"), value: $shortFocusBreak, in: 1...30)
                    Stepper(String(localized: "settings.longBreak \(shortFocusLongBreak)"), value: $shortFocusLongBreak, in: 1...60)
                }

                Section("🐢 " + String(localized: "settings.deepFocus")) {
                    Stepper(String(localized: "settings.work \(deepFocusWork)"), value: $deepFocusWork, in: 1...60)
                    Stepper(String(localized: "settings.break \(deepFocusBreak)"), value: $deepFocusBreak, in: 1...30)
                    Stepper(String(localized: "settings.longBreak \(deepFocusLongBreak)"), value: $deepFocusLongBreak, in: 1...60)
                }

                Section(String(localized: "settings.breakLock")) {
                    Toggle(String(localized: "settings.breakLock.enabled"), isOn: $strictBreakMode)
                        .help(String(localized: "settings.breakLock.help"))
                }

                Section(String(localized: "settings.sound")) {
                    Toggle(String(localized: "settings.sound.enabled"), isOn: $soundEnabled)

                    if soundEnabled {
                        HStack {
                            Picker(String(localized: "settings.sound.completion"), selection: $completionSound) {
                                ForEach(timer.availableSounds, id: \.self) { sound in
                                    Text(sound).tag(sound)
                                }
                            }
                            Button("▶") {
                                timer.soundVolume = soundVolume
                                playSound(completionSound)
                            }
                            .buttonStyle(.bordered)
                        }

                        Toggle(String(localized: "settings.sound.separateStart"), isOn: $separateStartEndSounds)

                        if separateStartEndSounds {
                            HStack {
                                Picker(String(localized: "settings.sound.start"), selection: $startSound) {
                                    ForEach(timer.availableSounds, id: \.self) { sound in
                                        Text(sound).tag(sound)
                                    }
                                }
                                Button("▶") {
                                    timer.soundVolume = soundVolume
                                    playSound(startSound)
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        HStack {
                            Text(String(localized: "settings.sound.volume"))
                            Slider(value: $soundVolume, in: 0...1)
                        }
                    }
                }

                Section {
                    Toggle(String(localized: "settings.import.allowList"), isOn: $importAllowListFormat)
                        .help(String(localized: "settings.import.allowList.help"))
                    Text(String(localized: "settings.import.allowList.tradeoff"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text(String(localized: "settings.import"))
                }

                Section(String(localized: "settings.export")) {
                    Picker(String(localized: "settings.export.indent"), selection: $indentStyle) {
                        Text(String(localized: "settings.export.spaces")).tag("spaces")
                        Text(String(localized: "settings.export.tab")).tag("tab")
                    }
                    .pickerStyle(.segmented)

                    if indentStyle == "spaces" {
                        Stepper(String(localized: "settings.export.spaceCount \(indentSpaces)"), value: $indentSpaces, in: 1...8)
                    }
                }

                Section(String(localized: "settings.language")) {
                    Picker(String(localized: "settings.language"), selection: $appLanguage) {
                        Text(String(localized: "settings.language.system")).tag("system")
                        Text("English").tag("en")
                        Text("日本語").tag("ja")
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button(String(localized: "button.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "button.save")) {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 340, height: 520)
        .onAppear { reloadDrafts() }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(importAllowListFormat, forKey: "importAllowListFormat")
        defaults.set(indentStyle, forKey: "indentStyle")
        defaults.set(indentSpaces, forKey: "indentSpaces")
        defaults.set(shortFocusWork, forKey: "shortFocusWork")
        defaults.set(shortFocusBreak, forKey: "shortFocusBreak")
        defaults.set(shortFocusLongBreak, forKey: "shortFocusLongBreak")
        defaults.set(deepFocusWork, forKey: "deepFocusWork")
        defaults.set(deepFocusBreak, forKey: "deepFocusBreak")
        defaults.set(deepFocusLongBreak, forKey: "deepFocusLongBreak")
        defaults.set(strictBreakMode, forKey: "strictBreakMode")
        defaults.set(appLanguage, forKey: "appLanguage")
        applyLanguage(appLanguage)

        // 選択中プリセットの時間を「このシートで編集した場合だけ」タイマーへ反映する。
        // updateSettings は走行中のサイクルを畳んでしまうので、
        // タイマーの現在値ではなく開いたときの下書きと比べる（両者はもともと食い違いうる）
        let active = activePresetMinutes
        let changed = active != initialPresetMinutes
            || cycleCount != timer.pomodorosUntilLongBreak
        if changed {
            timer.updateSettings(
                workMinutes: active.work,
                breakMinutes: active.breakMin,
                longBreakMinutes: active.longBreak,
                pomodorosUntilLongBreak: cycleCount
            )
        }

        timer.soundEnabled = soundEnabled
        timer.completionSound = completionSound
        timer.startSound = startSound
        timer.separateStartEndSounds = separateStartEndSounds
        timer.soundVolume = soundVolume
    }

    private func playSound(_ soundName: String) {
        if let sound = NSSound(named: soundName) {
            sound.volume = Float(soundVolume)
            sound.play()
        }
    }

    private func applyLanguage(_ language: String) {
        if language == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language], forKey: "AppleLanguages")
        }
    }
}

// MARK: - Modifier Key Aware Priority Buttons

struct ModifierKeyAwarePriorityButtons: View {
    @Binding var activePriority: Priority
    let onAdd: (Priority) -> Void
    let isDisabled: Bool
    let colorFor: (Priority) -> Color

    @StateObject private var monitor = ModifierKeyMonitor()

    var body: some View {
        HStack(spacing: 4) {
            priorityButton(.low, "!")
            priorityButton(.medium, "!!")
            priorityButton(.high, "!!!")
        }
        .onChange(of: monitor.currentPriority) { _, newValue in
            activePriority = newValue
        }
    }

    private func priorityButton(_ priority: Priority, _ label: String) -> some View {
        let isActive = priority == activePriority
        return Button(action: { onAdd(priority) }) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(isActive ? colorFor(priority) : colorFor(priority).opacity(0.4))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(isActive ? colorFor(priority).opacity(0.25) : colorFor(priority).opacity(0.08))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

/// 修飾キーを監視するクラス
class ModifierKeyMonitor: ObservableObject {
    @Published var currentPriority: Priority = .medium
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.updateFromModifiers(event.modifierFlags)
            return event
        }
    }

    deinit {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func updateFromModifiers(_ flags: NSEvent.ModifierFlags) {
        DispatchQueue.main.async { [weak self] in
            if flags.contains(.command) {
                self?.currentPriority = .high
            } else if flags.contains(.shift) {
                self?.currentPriority = .low
            } else {
                self?.currentPriority = .medium
            }
        }
    }
}

// MARK: - Quick Capture

/// 集中を切らずに思考を捕捉するための軽量シート
struct QuickCaptureView: View {
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                    .foregroundColor(.secondary)
                Text(String(localized: "quickCapture.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(1)
                Spacer()
            }

            TextField(String(localized: "quickCapture.placeholder"), text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($focused)
                .lineLimit(3...6)
                .onSubmit {
                    if !text.isEmpty { onSave() }
                }

            HStack {
                Text(String(localized: "quickCapture.hint"))
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.6))
                Spacer()
                Button(String(localized: "button.cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "button.save")) { onSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focused = true }
    }
}

// MARK: - Hold To Skip Button

/// 長押しで発火するボタン（休憩中の摩擦用）
struct HoldToSkipButton: View {
    let holdSeconds: Double
    let action: () -> Void

    @State private var progress: Double = 0
    @State private var holdTask: Task<Void, Never>?
    @State private var isHolding = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                .frame(width: 44, height: 44)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 44, height: 44)
                .rotationEffect(.degrees(-90))

            Image(systemName: "forward.fill")
                .font(.system(size: 12))
                .foregroundColor(isHolding ? .accentColor : .secondary)
        }
        .scaleEffect(isHolding ? 1.08 : 1.0)
        .animation(.easeOut(duration: 0.1), value: isHolding)
        .help(String(localized: "breakLock.holdToSkip"))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isHolding {
                        startHold()
                    }
                }
                .onEnded { _ in
                    cancelHold()
                }
        )
    }

    private func startHold() {
        isHolding = true
        let steps = 30
        let stepDuration = holdSeconds / Double(steps)
        let stepNanos = UInt64(stepDuration * 1_000_000_000)
        holdTask = Task { @MainActor in
            for i in 1...steps {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: stepNanos)
                if Task.isCancelled { return }
                withAnimation(.linear(duration: stepDuration)) {
                    progress = Double(i) / Double(steps)
                }
            }
            // 完了 — アクション発火
            action()
            withAnimation(.easeOut(duration: 0.2)) {
                progress = 0
                isHolding = false
            }
            holdTask = nil
        }
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
        withAnimation(.easeOut(duration: 0.2)) {
            progress = 0
            isHolding = false
        }
    }
}

// MARK: - Break Lock Window (Fullscreen)

/// 休憩中に全画面ロックウィンドウを管理するコントローラー
@MainActor
/// borderless な NSWindow は既定でキーウィンドウになれず、
/// SwiftUI の .keyboardShortcut が一切効かなくなるので明示的に許可する
final class KeyableBorderlessWindow: NSWindow {
    nonisolated override var canBecomeKey: Bool { true }
    nonisolated override var canBecomeMain: Bool { true }
}

@MainActor
final class BreakLockWindowController: ObservableObject {
    private var window: NSWindow?

    func show(timer: PomodoroTimer, onSkip: @escaping () -> Void) {
        guard window == nil else { return }

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let lockWindow = KeyableBorderlessWindow(
            contentRect: screenFrame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        lockWindow.isOpaque = false
        lockWindow.backgroundColor = .clear
        lockWindow.hasShadow = false
        lockWindow.level = .screenSaver
        lockWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        lockWindow.ignoresMouseEvents = false
        lockWindow.isMovable = false
        lockWindow.isReleasedWhenClosed = false
        lockWindow.setFrame(screenFrame, display: false)

        let view = BreakLockView(
            timer: timer,
            onSkip: { [weak self] in
                onSkip()
                self?.hide()
            }
        )
        let host = NSHostingView(rootView: view)
        host.frame = screenFrame
        host.autoresizingMask = [.width, .height]
        lockWindow.contentView = host
        lockWindow.makeKeyAndOrderFront(nil)

        self.window = lockWindow
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

/// 全画面ロックビュー
struct BreakLockView: View {
    @ObservedObject var timer: PomodoroTimer
    let onSkip: () -> Void

    @State private var pulse: Bool = false
    @State private var wellnessIndex: Int = 0
    @State private var wellnessTimer: Timer?

    private var phaseColor: Color {
        switch timer.currentPhase {
        case .work: return .blue
        case .break_: return .green
        case .longBreak: return .purple
        }
    }

    private var phaseLabel: String {
        switch timer.currentPhase {
        case .work: return ""
        case .break_: return String(localized: "phase.break \(timer.sessionPomodoros + 1) \(timer.pomodorosUntilLongBreak)")
        case .longBreak: return String(localized: "phase.longBreak")
        }
    }

    private var phaseProgress: Double {
        let total: Int
        switch timer.currentPhase {
        case .work: total = timer.workDuration
        case .break_: total = timer.breakDuration
        case .longBreak: total = timer.longBreakDuration
        }
        guard total > 0 else { return 0 }
        return 1.0 - (Double(timer.remainingSeconds) / Double(total))
    }

    /// 30秒ごとに切替わるウェルネスメッセージ
    private var wellnessMessages: [String] {
        [
            String(localized: "wellness.eyes"),
            String(localized: "wellness.stand"),
            String(localized: "wellness.shoulders"),
            String(localized: "wellness.hydrate"),
            String(localized: "wellness.breathe"),
        ]
    }

    private var currentWellness: String {
        let messages = wellnessMessages
        guard !messages.isEmpty else { return "" }
        return messages[wellnessIndex % messages.count]
    }

    private func formatTime(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    var body: some View {
        ZStack {
            // 暗いバックドロップで集中を崩す
            Rectangle()
                .fill(.ultraThickMaterial)
                .ignoresSafeArea()

            // 休憩色のソフトグロー（息づくように脈動）
            RadialGradient(
                colors: [phaseColor.opacity(pulse ? 0.28 : 0.18), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 700
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                // フェーズアイコン（脈動）
                Image(systemName: timer.currentPhase == .longBreak ? "moon.stars" : "leaf")
                    .font(.system(size: 44, weight: .ultraLight))
                    .foregroundColor(phaseColor.opacity(pulse ? 0.95 : 0.55))
                    .scaleEffect(pulse ? 1.04 : 1.0)

                // フェーズラベル
                Text(phaseLabel)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(2)

                // 進捗リング + 巨大タイマー
                ZStack {
                    Circle()
                        .stroke(phaseColor.opacity(0.12), lineWidth: 8)
                        .frame(width: 320, height: 320)

                    Circle()
                        .trim(from: 0, to: phaseProgress)
                        .stroke(phaseColor.opacity(0.85),
                                style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 320, height: 320)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.5), value: phaseProgress)

                    Text(formatTime(timer.remainingSeconds))
                        .font(.system(size: 110, weight: .ultraLight, design: .monospaced))
                        .foregroundColor(.primary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if timer.isRunning { timer.pause() } else { timer.start() }
                        }
                }

                // ローテーションするウェルネスメッセージ
                Text(currentWellness)
                    .font(.system(size: 17, weight: .light))
                    .foregroundColor(.primary.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .padding(.horizontal, 24)
                    .id(wellnessIndex)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))

                // 主メッセージ
                Text(String(localized: "breakLock.message"))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)

                // 長押しスキップ
                HoldToSkipButton(holdSeconds: 1.5) {
                    timer.skip()
                    onSkip()
                }
                .padding(.top, 8)
            }
            .padding(60)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                pulse.toggle()
            }
            // 30秒ごとにウェルネスメッセージを切替
            wellnessTimer?.invalidate()
            wellnessTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 0.6)) {
                        wellnessIndex += 1
                    }
                }
            }
        }
        .onDisappear {
            wellnessTimer?.invalidate()
            wellnessTimer = nil
        }
        // 背後への入力を完全にブロック
        .contentShape(Rectangle())
        .onTapGesture { /* 吸収 */ }
    }
}

// MARK: - Minimal Window (Borderless Child)

/// ミニマル表示用の独立 borderless 浮遊ウィンドウ
@MainActor
final class MinimalWindowController: ObservableObject {
    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private static let frameKey = "minimal_window_frame"
    static let fixedSize = NSSize(width: 220, height: 140)

    func show(timer: PomodoroTimer, taskListVM: TaskListViewModel, onExit: @escaping () -> Void) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // 固定サイズ、ユーザはリサイズ不可。位置だけ記憶
        let frame = NSRect(origin: savedOrigin() ?? defaultOrigin(), size: Self.fixedSize)

        let win = KeyableBorderlessWindow(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        // 起動時の pin 状態を適用
        let pinned = UserDefaults.standard.object(forKey: "minimalIsPinned") as? Bool ?? true
        win.level = pinned ? .floating : .normal
        win.isMovable = true
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isReleasedWhenClosed = false
        win.acceptsMouseMovedEvents = true
        // borderless でもキーになれるように
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true

        let view = MinimalTimerView(
            timer: timer,
            taskListVM: taskListVM,
            onExit: onExit
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        win.contentView = host

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // フレーム永続化
        let moveObs = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: win, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.persistFrame() }
        }
        let resizeObs = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: win, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.persistFrame() }
        }
        observers = [moveObs, resizeObs]

        self.window = win
    }

    func hide() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        window?.orderOut(nil)
        window = nil
    }

    private func persistFrame() {
        guard let frame = window?.frame else { return }
        // 位置のみ記憶（サイズは固定）
        let arr = [Double(frame.origin.x), Double(frame.origin.y)]
        UserDefaults.standard.set(arr, forKey: Self.frameKey)
    }

    private func savedOrigin() -> NSPoint? {
        guard let arr = UserDefaults.standard.array(forKey: Self.frameKey) as? [Double],
              arr.count >= 2 else { return nil }
        let point = NSPoint(x: arr[0], y: arr[1])
        // 画面内チェック
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(origin: point, size: Self.fixedSize)
        if !screen.intersects(rect) { return nil }
        return point
    }

    private func defaultOrigin() -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 画面右上に控えめに配置
        return NSPoint(
            x: screen.maxX - Self.fixedSize.width - 24,
            y: screen.maxY - Self.fixedSize.height - 24
        )
    }
}

/// ミニマルウィンドウのコンテンツビュー
struct MinimalTimerView: View {
    @ObservedObject var timer: PomodoroTimer
    @ObservedObject var taskListVM: TaskListViewModel
    let onExit: () -> Void

    @State private var hovering: Bool = false
    @AppStorage("minimalIsPinned") private var isPinned: Bool = true

    private var phaseColor: Color {
        switch timer.currentPhase {
        case .work: return .blue
        case .break_: return .green
        case .longBreak: return .purple
        }
    }

    private var phaseProgress: Double {
        let total: Int
        switch timer.currentPhase {
        case .work: total = timer.workDuration
        case .break_: total = timer.breakDuration
        case .longBreak: total = timer.longBreakDuration
        }
        guard total > 0 else { return 0 }
        return 1.0 - (Double(timer.remainingSeconds) / Double(total))
    }

    private var phaseLabel: String {
        switch timer.currentPhase {
        case .work:
            return String(localized: "phase.work \(timer.sessionPomodoros + 1) \(timer.pomodorosUntilLongBreak)")
        case .break_:
            return String(localized: "phase.break \(timer.sessionPomodoros + 1) \(timer.pomodorosUntilLongBreak)")
        case .longBreak:
            return String(localized: "phase.longBreak")
        }
    }

    private func formatTime(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    var body: some View {
        ZStack {
            // 角丸の背景 (window 自体が透明なので、ここで形を作る)
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(phaseColor.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )

            // メインコンテンツ
            VStack(spacing: 4) {
                Spacer(minLength: 6)

                // 巨大タイマー
                Text(formatTime(timer.remainingSeconds))
                    .font(.system(size: 52, weight: .ultraLight, design: .monospaced))
                    .foregroundColor(timer.isRunning ? .primary : .primary.opacity(0.5))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .contentShape(Rectangle())
                    .onTapGesture { toggleTimer() }

                // タスク名 (サブタスクなら直接の親も薄く prefix) or フェーズラベル
                Group {
                    if timer.currentPhase == .work, let task = taskListVM.currentTask {
                        HStack(spacing: 4) {
                            if let parent = directParentTitle(for: task) {
                                Text(parent)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary.opacity(0.4))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("▸")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary.opacity(0.3))
                            }
                            Text(task.title)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text(phaseLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(phaseColor.opacity(0.85))
                            .textCase(.uppercase)
                            .tracking(1.2)
                    }
                }
                .padding(.horizontal, 12)

                Spacer(minLength: 6)

                // 底辺の極細プログレスバー
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 2)
                        Capsule()
                            .fill(phaseColor.opacity(0.7))
                            .frame(width: geo.size.width * phaseProgress, height: 2)
                            .animation(.linear(duration: 0.5), value: phaseProgress)
                    }
                }
                .frame(height: 2)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            // 右上のホバーコントロール (pin + exit)
            VStack {
                HStack(spacing: 4) {
                    Spacer()
                    // Pin トグル
                    Button(action: { togglePin() }) {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(isPinned ? .accentColor : .secondary)
                            .frame(width: 18, height: 18)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "tooltip.minimalPin"))
                    .opacity(hovering ? 1.0 : 0)
                    .animation(.easeOut(duration: 0.15), value: hovering)

                    // Exit ボタン
                    Button(action: onExit) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 18, height: 18)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .help(String(localized: "tooltip.exitMinimal"))
                    .opacity(hovering ? 1.0 : 0)
                    .animation(.easeOut(duration: 0.15), value: hovering)
                }
                Spacer()
            }
            .padding(6)

            // キーボードショートカット (非表示ボタン)
            minimalShortcuts
        }
        .onHover { hovering = $0 }
        .onAppear { applyPinState() }
        .onChange(of: isPinned) { _, _ in applyPinState() }
    }

    private func togglePin() {
        isPinned.toggle()
    }

    private func applyPinState() {
        // ミニマルウィンドウの NSWindow を見つけて level を更新
        for win in NSApp.windows where win.styleMask.contains(.borderless) && win.contentView is NSHostingView<MinimalTimerView> {
            win.level = isPinned ? .floating : .normal
        }
    }

    private func toggleTimer() {
        if timer.isRunning { timer.pause() } else { timer.start() }
    }

    /// 直接の親タスクのタイトル (なければ nil)
    private func directParentTitle(for task: TodoTask) -> String? {
        guard let parentId = task.parentId,
              let parent = taskListVM.taskList.tasks.first(where: { $0.id == parentId }) else {
            return nil
        }
        return parent.title
    }

    private var minimalShortcuts: some View {
        Group {
            Button("") { toggleTimer() }
                .keyboardShortcut("p", modifiers: .command)
            Button("") {
                // ミニマル時は集中保護のためモーダル無しでカスケード完了 + 自動遷移
                if let task = taskListVM.currentTask {
                    taskListVM.completeTask(id: task.id)
                    _ = taskListVM.autoCompleteParentIfReady(for: task.id)
                    if taskListVM.currentTaskId == nil {
                        taskListVM.advanceToNextTask()
                    }
                }
            }
            .keyboardShortcut("d", modifiers: .command)
            Button("") {
                taskListVM.postponeCurrentTask()
            }
            .keyboardShortcut("l", modifiers: .command)
            Button("") {
                timer.skip()
            }
            .keyboardShortcut("s", modifiers: .command)
            Button("") {
                timer.resetCycle()
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
