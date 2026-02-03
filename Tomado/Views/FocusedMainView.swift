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
    @AppStorage("sortState") private var sortState: SortState = .unsorted  // ソート状態
    @AppStorage("isTopmost") private var isTopmost: Bool = false  // 最前面固定
    @AppStorage("viewMode") private var viewMode: ViewMode = .separated  // 表示モード
    @AppStorage("timerPreset") private var timerPreset: TimerPreset = .shortFocus  // タイマープリセット
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
        VStack(spacing: 0) {
            // 入力エリア
            inputSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            // メインエリア（現在のタスク + タイマー）
            if let currentTask = taskListVM.currentTask {
                currentTaskSection(currentTask)
            } else {
                emptyStateView
            }

            Divider()

            // 待機タスクリスト
            taskListSection

            Divider()

            // フッター
            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            isInputFocused = true
            updateTimerTask()
            // Restore topmost state
            if let window = NSApp.windows.first {
                window.level = isTopmost ? .floating : .normal
            }
        }
        .onChange(of: taskListVM.currentTask?.id) { _, _ in
            updateTimerTask()
        }
        .onChange(of: taskListVM.taskList.tasks) { _, _ in
            updateTimerTask()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(timer: timer)
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
        VStack(spacing: 16) {
            Spacer()

            // タスク名 + 優先度
            HStack(spacing: 8) {
                Text(task.priority.symbol)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(colorFor(task.priority))
                Text(task.title)
                    .font(.system(size: 20, weight: .medium))
            }
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 24)

            // タイマー
            timerDisplay

            // コントロール
            controlButtons(task)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var timerDisplay: some View {
        VStack(spacing: 4) {
            Text(formatTime(timer.remainingSeconds))
                .font(.system(size: 48, weight: .light, design: .monospaced))

            Text(phaseText)
                .font(.caption)
                .foregroundColor(phaseColor)
        }
        .onTapGesture {
            toggleTimer()
        }
    }

    private func controlButtons(_ task: TodoTask) -> some View {
        HStack(spacing: 20) {
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
                size: 56,
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
        size: CGFloat = 28,
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
            // unsortedに戻る（保存された順序をリロード）
            taskListVM.reload()
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
        if let window = NSApp.windows.first {
            window.level = isTopmost ? .floating : .normal
        }
        showToast(isTopmost ? String(localized: "toast.topmostOn") : String(localized: "toast.topmostOff"))
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
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundColor(.green.opacity(0.5))
            Text(String(localized: "empty.title"))
                .font(.headline)
                .foregroundColor(.secondary)
            Text(String(localized: "empty.message"))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
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
            let currentTaskId = taskListVM.currentTask?.id
            let ancestorIds = currentTaskId.map { taskListVM.getAncestorIds(for: $0) } ?? []

            if !hierarchyTasks.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // 階層順でタスクを表示（親→子）
                        ForEach(Array(hierarchyTasks.enumerated()), id: \.element.id) { _, task in
                            let isCurrent = task.id == currentTaskId
                            let ancestorIndex = ancestorIds.firstIndex(of: task.id)

                            VStack(spacing: 0) {
                                // 挿入ライン（ドロップターゲット）
                                insertLine(beforeTaskId: task.id)

                                // タスク行
                                taskRow(task, isCurrent: isCurrent, ancestorIndex: ancestorIndex)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(taskRowBackground(task, isCurrent: isCurrent, ancestorIndex: ancestorIndex))
                            }
                        }

                        // 完了タスク
                        let completedTasks = taskListVM.taskList.tasks.filter { $0.isCompleted }
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
            } else if taskListVM.taskList.tasks.isEmpty {
                Color.clear.frame(height: 100)
            } else {
                Color.clear.frame(height: 50)
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
                                    insertLine(beforeTaskId: task.id)
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
                Text("\(task.pomodoros)🍅")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .contextMenu {
            Button(String(localized: "button.uncomplete")) {
                taskListVM.uncompleteTask(id: task.id)
            }
            Button(String(localized: "button.delete"), role: .destructive) {
                taskListVM.deleteTask(id: task.id)
            }
        }
    }

    /// 挿入ライン（D&Dで割り込み挿入用）
    private func insertLine(beforeTaskId: String) -> some View {
        Rectangle()
            .fill(insertBeforeId == beforeTaskId ? Color.accentColor : Color.clear)
            .frame(height: insertBeforeId == beforeTaskId ? 3 : 1)
            .contentShape(Rectangle().size(width: .infinity, height: 12))  // タッチ領域は広めに
            .dropDestination(for: String.self) { droppedIds, _ in
                guard let droppedId = droppedIds.first,
                      droppedId != beforeTaskId else { return false }
                taskListVM.insertTask(droppedId, before: beforeTaskId)
                sortState = .unsorted
                return true
            } isTargeted: { isTargeted in
                insertBeforeId = isTargeted ? beforeTaskId : nil
            }
    }

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

            // タスク名
            Text(task.title)
                .font(task.isRoot ? .body : .callout)
                .foregroundColor(task.isRoot || isCurrent ? .primary : .secondary)
                .fontWeight(isCurrent ? .medium : .regular)
                .lineLimit(1)

            Spacer()

            if task.pomodoros > 0 {
                Text("\(task.pomodoros)🍅")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // サブタスク解除ボタン
            if !task.isRoot {
                Button(action: { taskListVM.makeRootTask(taskId: task.id) }) {
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
            Button(String(localized: "button.delete"), role: .destructive) { taskListVM.deleteTask(id: task.id) }
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
        if let index = taskListVM.taskList.tasks.firstIndex(where: { $0.id == task.id }) {
            taskListVM.taskList.tasks[index].priority = priority
        }
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
                Text("\(task.pomodoros)🍅")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contextMenu {
            Button(String(localized: "button.uncomplete")) {
                taskListVM.uncompleteTask(id: task.id)
            }
            Button(String(localized: "button.delete"), role: .destructive) {
                taskListVM.deleteTask(id: task.id)
            }
        }
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        HStack(spacing: 12) {
            let stats = taskListVM.taskList.stats
            Text("\(stats.completed)/\(stats.total)")
                .font(.caption)
                .foregroundColor(.secondary)

            if stats.pomodoros > 0 {
                Text("・\(stats.pomodoros)🍅")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // タイマープリセット切替 (⌘⇧T)
            timerPresetButton()
                .keyboardShortcut("t", modifiers: [.command, .shift])

            // 最前面固定 (⌘⇧P)
            topmostButton()
                .keyboardShortcut("p", modifiers: [.command, .shift])

            // ビューモード切替 (⌘⇧V)
            viewModeButton()
                .keyboardShortcut("v", modifiers: [.command, .shift])

            // ソート (⌘⇧S)
            sortButton()
                .disabled(taskListVM.taskList.tasks.isEmpty)
                .keyboardShortcut("s", modifiers: [.command, .shift])

            // 完了削除（クリック時はダイアログ）
            footerButton(id: "clearCompleted", icon: "checkmark.circle.badge.xmark") {
                showClearCompletedConfirm = true
            }
            .disabled(taskListVM.taskList.tasks.filter { $0.isCompleted }.isEmpty)
            .keyboardShortcut(.delete, modifiers: .command)

            // 全削除（クリック時はダイアログ）
            footerButton(id: "clearAll", icon: "trash") {
                showClearAllConfirm = true
            }
            .disabled(taskListVM.taskList.tasks.isEmpty)
            .keyboardShortcut(.delete, modifiers: [.command, .shift])

            // インポート (⌘V)
            footerButton(id: "import", icon: "square.and.arrow.down") {
                let count = taskListVM.importFromClipboard()
                if count > 0 {
                    // インポート後、現在のソート状態を適用
                    if sortState != .unsorted {
                        taskListVM.sort(ascending: sortState == .ascending)
                    }
                    showToast(String(localized: "toast.imported \(count)"))
                }
            }
            .keyboardShortcut("v", modifiers: .command)

            // エクスポート (⌘C)
            footerButton(id: "export", icon: "square.and.arrow.up") {
                taskListVM.exportToClipboard()
                showToast(String(localized: "toast.exported"))
            }
            .disabled(taskListVM.taskList.tasks.isEmpty)
            .keyboardShortcut("c", modifiers: .command)

            // 設定
            footerButton(id: "settings", icon: "gear") {
                showSettings = true
            }
        }
    }

    // MARK: - Helpers

    private func toggleTimer() {
        if timer.isRunning {
            timer.pause()
        } else {
            timer.start()
        }
    }

    private func completeCurrentTask() {
        if let task = taskListVM.currentTask {
            taskListVM.completeTask(id: task.id)
            showToast(String(localized: "toast.completed"))
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
            // タスクがなくなったらタイマー停止（ポモドーロは継続）
            if timer.isRunning {
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

    // インポート/エクスポート設定
    @AppStorage("importAllowListFormat") private var importAllowListFormat: Bool = false
    @AppStorage("indentStyle") private var indentStyle: String = "spaces"
    @AppStorage("indentSpaces") private var indentSpaces: Int = 2

    // 言語設定
    @AppStorage("appLanguage") private var appLanguage: String = "system"

    // タイマープリセット設定
    @AppStorage("shortFocusWork") private var shortFocusWork: Int = 12
    @AppStorage("shortFocusBreak") private var shortFocusBreak: Int = 3
    @AppStorage("shortFocusLongBreak") private var shortFocusLongBreak: Int = 15
    @AppStorage("deepFocusWork") private var deepFocusWork: Int = 35
    @AppStorage("deepFocusBreak") private var deepFocusBreak: Int = 10
    @AppStorage("deepFocusLongBreak") private var deepFocusLongBreak: Int = 30

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

                Section(String(localized: "settings.import")) {
                    Toggle(String(localized: "settings.import.allowList"), isOn: $importAllowListFormat)
                        .help(String(localized: "settings.import.allowList.help"))
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
                    .onChange(of: appLanguage) { _, newValue in
                        applyLanguage(newValue)
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
    }

    private func save() {
        timer.updateSettings(
            workMinutes: workMinutes,
            breakMinutes: breakMinutes,
            longBreakMinutes: longBreakMinutes,
            pomodorosUntilLongBreak: cycleCount
        )
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
