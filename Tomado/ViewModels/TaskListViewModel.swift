import AppKit
import Foundation
import SwiftUI

@MainActor
public class TaskListViewModel: ObservableObject {
    @Published public var taskList: TaskList = TaskList()
    @Published public var currentTaskId: String?  // 現在選択中のタスクID

    private let storageURL: URL

    public init() {
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDir = appSupportURL.appendingPathComponent("com.tomado.app", isDirectory: true)
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.storageURL = appDir.appendingPathComponent("tasks.json")
        load()
    }

    // MARK: - Task Operations

    /// タスク追加
    public func addTask(title: String, priority: Priority = .medium, parentId: String? = nil) {
        // 親がある場合はインデントレベルを計算
        var indentLevel = 0
        if let parentId = parentId,
           let parent = taskList.tasks.first(where: { $0.id == parentId }) {
            indentLevel = parent.indentLevel + 1
        }

        let task = TodoTask(
            title: title,
            priority: priority,
            parentId: parentId,
            indentLevel: indentLevel
        )

        // 親がある場合は親の直前に挿入（実行順）
        if let parentId = parentId,
           let parentIndex = taskList.tasks.firstIndex(where: { $0.id == parentId }) {
            taskList.tasks.insert(task, at: parentIndex)
        } else {
            taskList.tasks.insert(task, at: findInsertIndex(for: priority))
        }

        taskList.lastModified = Date()
        save()
    }

    /// 優先度に基づいて挿入位置を決定（ルートタスクのみ対象）
    private func findInsertIndex(for priority: Priority) -> Int {
        let incomplete = taskList.tasks.enumerated().filter { !$0.element.isCompleted && $0.element.isRoot }
        for (index, task) in incomplete {
            if task.priority.rawValue < priority.rawValue {
                return index
            }
        }
        // 未完了タスクの末尾
        return taskList.tasks.firstIndex { $0.isCompleted } ?? taskList.tasks.count
    }

    /// タスク完了（サブタスクも一緒に完了）
    public func completeTask(id: String) {
        // サブタスクを先に完了
        let subtaskIds = getSubtaskIds(for: id)
        var updatedTasks = taskList.tasks

        for subtaskId in subtaskIds {
            if let index = updatedTasks.firstIndex(where: { $0.id == subtaskId }) {
                updatedTasks[index].isCompleted = true
            }
        }

        // 本タスクを完了
        if let index = updatedTasks.firstIndex(where: { $0.id == id }) {
            updatedTasks[index].isCompleted = true
        }

        // 完了タスクを末尾に移動
        let completedIds = Set([id] + subtaskIds)
        let completedTasks = updatedTasks.filter { completedIds.contains($0.id) }
        updatedTasks.removeAll { completedIds.contains($0.id) }
        updatedTasks.append(contentsOf: completedTasks)

        // 完了したタスクが選択中だったら選択をクリア
        if completedIds.contains(currentTaskId ?? "") {
            currentTaskId = nil
        }

        // 一度に更新して確実に通知（structなので代入で通知される）
        taskList = TaskList(tasks: updatedTasks, lastModified: Date())
        save()
    }

    /// タスクを未完了に戻す（親タスクも一緒に未完了にする）
    public func uncompleteTask(id: String) {
        var updatedTasks = taskList.tasks

        // 対象タスクと全ての祖先を未完了に
        let ancestorIds = getAncestorIds(for: id)
        let idsToUncomplete = Set([id] + ancestorIds)

        for taskId in idsToUncomplete {
            if let index = updatedTasks.firstIndex(where: { $0.id == taskId }) {
                updatedTasks[index].isCompleted = false
            }
        }

        // 未完了に戻したタスクを未完了リストの末尾に移動
        let uncompletedTasks = updatedTasks.filter { idsToUncomplete.contains($0.id) }
        updatedTasks.removeAll { idsToUncomplete.contains($0.id) }
        let insertIndex = updatedTasks.firstIndex { $0.isCompleted } ?? updatedTasks.count
        updatedTasks.insert(contentsOf: uncompletedTasks, at: insertIndex)

        taskList = TaskList(tasks: updatedTasks, lastModified: Date())
        save()
    }

    /// 指定タスクのサブタスクIDを再帰的に取得
    private func getSubtaskIds(for parentId: String) -> [String] {
        var result: [String] = []
        let directChildren = taskList.tasks.filter { $0.parentId == parentId }
        for child in directChildren {
            result.append(contentsOf: getSubtaskIds(for: child.id))
            result.append(child.id)
        }
        return result
    }

    /// タスク削除（サブタスクも削除）
    public func deleteTask(id: String) {
        let subtaskIds = getSubtaskIds(for: id)
        let idsToDelete = Set([id] + subtaskIds)
        taskList.tasks.removeAll { idsToDelete.contains($0.id) }

        // 削除したタスクが選択中だったら選択をクリア
        if idsToDelete.contains(currentTaskId ?? "") {
            currentTaskId = nil
        }

        taskList.lastModified = Date()
        save()
    }

    /// タスクをサブタスク化（無制限階層対応）
    public func makeSubtask(taskId: String, parentId: String) {
        guard let taskIndex = taskList.tasks.firstIndex(where: { $0.id == taskId }),
              let parent = taskList.tasks.first(where: { $0.id == parentId }) else { return }

        // 循環参照チェック（親が自分の子孫でないことを確認）
        if isDescendant(parentId, of: taskId) { return }

        taskList.tasks[taskIndex].parentId = parentId
        taskList.tasks[taskIndex].indentLevel = parent.indentLevel + 1

        // サブタスクも一緒にインデントレベルを更新
        updateDescendantIndentLevels(for: taskId, baseLevel: parent.indentLevel + 1)

        // 親の直前に移動
        if let parentIndex = taskList.tasks.firstIndex(where: { $0.id == parentId }) {
            let task = taskList.tasks.remove(at: taskIndex)
            let newIndex = taskIndex < parentIndex ? parentIndex - 1 : parentIndex
            taskList.tasks.insert(task, at: newIndex)
        }

        taskList.lastModified = Date()
        save()
    }

    /// 指定タスクが別タスクの子孫かどうかをチェック
    private func isDescendant(_ taskId: String, of ancestorId: String) -> Bool {
        var current = taskId
        while let task = taskList.tasks.first(where: { $0.id == current }) {
            if task.parentId == ancestorId { return true }
            if let parentId = task.parentId {
                current = parentId
            } else {
                break
            }
        }
        return false
    }

    /// 子孫のインデントレベルを更新
    private func updateDescendantIndentLevels(for parentId: String, baseLevel: Int) {
        let children = taskList.tasks.filter { $0.parentId == parentId }
        for child in children {
            if let index = taskList.tasks.firstIndex(where: { $0.id == child.id }) {
                taskList.tasks[index].indentLevel = baseLevel + 1
                updateDescendantIndentLevels(for: child.id, baseLevel: baseLevel + 1)
            }
        }
    }

    /// サブタスクを独立タスクに（子孫も一緒にルート化）
    public func makeRootTask(taskId: String) {
        guard let index = taskList.tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let oldLevel = taskList.tasks[index].indentLevel
        taskList.tasks[index].parentId = nil
        taskList.tasks[index].indentLevel = 0

        // 子孫のインデントレベルを調整（差分を適用）
        adjustDescendantLevels(for: taskId, levelDiff: -oldLevel)

        taskList.lastModified = Date()
        save()
    }

    /// 子孫のインデントレベルを差分で調整
    private func adjustDescendantLevels(for parentId: String, levelDiff: Int) {
        let children = taskList.tasks.filter { $0.parentId == parentId }
        for child in children {
            if let index = taskList.tasks.firstIndex(where: { $0.id == child.id }) {
                taskList.tasks[index].indentLevel = max(0, taskList.tasks[index].indentLevel + levelDiff)
                adjustDescendantLevels(for: child.id, levelDiff: levelDiff)
            }
        }
    }

    /// 階層順（親→子）で未完了タスクを取得
    public func tasksInHierarchyOrder() -> [TodoTask] {
        var result: [TodoTask] = []
        let incompleteRoots = taskList.tasks.filter { $0.isRoot && !$0.isCompleted }

        func addWithChildren(_ task: TodoTask) {
            result.append(task)
            let children = taskList.tasks.filter { $0.parentId == task.id && !$0.isCompleted }
            for child in children {
                addWithChildren(child)
            }
        }

        for root in incompleteRoots {
            addWithChildren(root)
        }

        return result
    }

    /// 階層順（親→子）で全タスク（完了/未完了混合）を取得
    public func allTasksInHierarchyOrder() -> [TodoTask] {
        var result: [TodoTask] = []
        let roots = taskList.tasks.filter { $0.isRoot }

        func addWithChildren(_ task: TodoTask) {
            result.append(task)
            let children = taskList.tasks.filter { $0.parentId == task.id }
            for child in children {
                addWithChildren(child)
            }
        }

        for root in roots {
            addWithChildren(root)
        }

        return result
    }

    /// 指定タスクの祖先IDリストを取得（直近の親から順に）
    public func getAncestorIds(for taskId: String) -> [String] {
        var ancestors: [String] = []
        var currentId = taskId

        while let task = taskList.tasks.first(where: { $0.id == currentId }),
              let parentId = task.parentId {
            ancestors.append(parentId)
            currentId = parentId
        }

        return ancestors
    }

    /// 現在のタスク（選択中または最初の未完了タスク）
    public var currentTask: TodoTask? {
        if let id = currentTaskId,
           let task = taskList.tasks.first(where: { $0.id == id && !$0.isCompleted }) {
            return task
        }
        // 選択がない or 選択タスクが完了済みなら最初の未完了タスク
        return taskList.tasks.first { !$0.isCompleted }
    }

    /// タスクを選択（現在のタスクに設定）
    public func selectTask(id: String) {
        // 未完了タスクのみ選択可能
        guard let task = taskList.tasks.first(where: { $0.id == id }),
              !task.isCompleted else { return }
        currentTaskId = id
    }

    /// 現在のタスクにポモドーロ追加
    public func addPomodoroToCurrentTask() {
        guard let task = currentTask,
              let index = taskList.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        taskList.tasks[index].addPomodoro()
        taskList.lastModified = Date()
        save()
    }

    /// タスクを別のタスクの前に挿入（割り込み用）
    public func insertTask(_ taskId: String, before targetId: String) {
        guard let taskIndex = taskList.tasks.firstIndex(where: { $0.id == taskId }),
              let targetIndex = taskList.tasks.firstIndex(where: { $0.id == targetId }) else { return }

        let task = taskList.tasks.remove(at: taskIndex)
        let newTargetIndex = taskIndex < targetIndex ? targetIndex - 1 : targetIndex
        taskList.tasks.insert(task, at: newTargetIndex)

        taskList.lastModified = Date()
        save()
    }

    /// タスクのルートを取得
    public func getRootTask(for taskId: String) -> TodoTask? {
        var currentId = taskId
        while let task = taskList.tasks.first(where: { $0.id == currentId }) {
            if task.isRoot {
                return task
            }
            if let parentId = task.parentId {
                currentId = parentId
            } else {
                break
            }
        }
        return nil
    }

    /// タスクを後回しにする（選択を次のタスクに移動）
    public func postponeCurrentTask() {
        guard let current = currentTask else { return }

        // 現在のタスクのインデックスを取得
        guard let currentIndex = taskList.tasks.firstIndex(where: { $0.id == current.id }) else { return }

        // 次の未完了タスクを探す
        for i in (currentIndex + 1)..<taskList.tasks.count {
            if !taskList.tasks[i].isCompleted {
                currentTaskId = taskList.tasks[i].id
                return
            }
        }

        // 次がなければ最初の未完了タスクに戻る
        if let first = taskList.tasks.first(where: { !$0.isCompleted }) {
            currentTaskId = first.id
        }
    }

    /// ソート（ルートタスクの優先度のみ、サブタスク構造は維持）
    public func sort(ascending: Bool = false) {
        taskList.sort(ascending: ascending)
        save()
    }

    /// 全クリア
    public func clearAll() {
        taskList.tasks.removeAll()
        taskList.lastModified = Date()
        save()
    }

    /// 完了タスクのみクリア
    public func clearCompleted() {
        taskList.tasks.removeAll { $0.isCompleted }
        taskList.lastModified = Date()
        save()
    }

    /// 並び替え
    public func move(from source: IndexSet, to destination: Int) {
        taskList.tasks.move(fromOffsets: source, toOffset: destination)
        taskList.lastModified = Date()
        save()
    }

    // MARK: - Import/Export

    /// クリップボードからインポート（階層構造対応）
    public func importFromClipboard() -> Int {
        guard let text = NSPasteboard.general.string(forType: .string) else { return 0 }
        let lines = text.components(separatedBy: .newlines)

        // 設定を取得
        let allowListFormat = UserDefaults.standard.bool(forKey: "importAllowListFormat")

        // インデント自動検知: タブがあればタブ単位、なければスペース数を検出
        let detectedIndent = detectIndentUnit(in: text)

        // パース結果を一時保存
        enum ParsedItem {
            case task(title: String, priority: Priority, isCompleted: Bool, indentLevel: Int)
            case note(text: String, indentLevel: Int)
        }

        var parsed: [ParsedItem] = []

        for line in lines {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let indentLevel = calculateIndentLevel(line: line, indentUnit: detectedIndent)
            var content = line.trimmingCharacters(in: .whitespaces)

            // Markdown チェックボックス形式をタスクとしてパース
            var isTask = false
            var isCompleted = false
            if content.hasPrefix("- [x]") || content.hasPrefix("- [X]") {
                content = String(content.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                isCompleted = true
                isTask = true
            } else if content.hasPrefix("- [ ]") {
                content = String(content.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                isTask = true
            } else if allowListFormat,
                      content.hasPrefix("- ") || content.hasPrefix("* ") {
                content = String(content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                isTask = true
            } else if allowListFormat, let match = content.firstMatch(of: /^\d+\.\s+/) {
                content = String(content.dropFirst(match.0.count)).trimmingCharacters(in: .whitespaces)
                isTask = true
            } else if (content.hasPrefix("- ") || content.hasPrefix("* ") || content.hasPrefix("> "))
                      && indentLevel > 0 {
                // インデントされた非チェックボックス bullet/quote → 注釈/メモ扱い
                let stripped: String
                if content.hasPrefix("> ") {
                    stripped = String(content.dropFirst(2))
                } else {
                    stripped = String(content.dropFirst(2))
                }
                let noteText = stripped.trimmingCharacters(in: .whitespaces)
                if !noteText.isEmpty {
                    parsed.append(.note(text: noteText, indentLevel: indentLevel))
                }
                continue
            }

            guard isTask, !content.isEmpty else { continue }

            // 優先度をパース
            var priority: Priority = .medium
            if content.hasSuffix(" !!!") {
                priority = .high
                content = String(content.dropLast(4))
            } else if content.hasSuffix(" !!") {
                priority = .medium
                content = String(content.dropLast(3))
            } else if content.hasSuffix(" !") {
                priority = .low
                content = String(content.dropLast(2))
            }

            parsed.append(.task(title: content, priority: priority, isCompleted: isCompleted, indentLevel: indentLevel))
        }

        guard !parsed.isEmpty else { return 0 }

        // 親子関係を構築しながらタスク + メモを実体化
        var parentStack: [(level: Int, id: String, actualIndent: Int)] = []
        var addedTasks: [TodoTask] = []
        var notesByTaskId: [String: [String]] = [:]
        var lastTaskId: String?
        var lastTaskLevel: Int = -1

        for item in parsed {
            switch item {
            case let .task(title, priority, isCompleted, indentLevel):
                while !parentStack.isEmpty && parentStack.last!.level >= indentLevel {
                    parentStack.removeLast()
                }
                let parentId = parentStack.last?.id
                let actualIndentLevel = parentStack.last.map { $0.actualIndent + 1 } ?? 0

                let task = TodoTask(
                    title: title,
                    priority: priority,
                    isCompleted: isCompleted,
                    parentId: parentId,
                    indentLevel: actualIndentLevel
                )
                addedTasks.append(task)
                parentStack.append((level: indentLevel, id: task.id, actualIndent: actualIndentLevel))
                lastTaskId = task.id
                lastTaskLevel = indentLevel

            case let .note(text, indentLevel):
                // 直前のタスク (より浅いインデント) に紐付け
                guard let id = lastTaskId, indentLevel > lastTaskLevel else { continue }
                notesByTaskId[id, default: []].append(text)
            }
        }

        // notes をマージしてタスクに付与
        for i in addedTasks.indices {
            if let lines = notesByTaskId[addedTasks[i].id] {
                addedTasks[i].notes = lines.joined(separator: "\n")
            }
        }

        taskList.tasks.append(contentsOf: addedTasks)
        save()

        return addedTasks.count
    }

    /// クリップボードにエクスポート（階層構造対応）
    public func exportToClipboard() {
        // 設定を取得
        let indentStyle = UserDefaults.standard.string(forKey: "indentStyle") ?? "spaces"
        let indentSpaces = UserDefaults.standard.integer(forKey: "indentSpaces")
        let spacesPerLevel = indentSpaces > 0 ? indentSpaces : 2

        let indentUnit = indentStyle == "tab" ? "\t" : String(repeating: " ", count: spacesPerLevel)

        // 表示用に階層順（親→サブタスク）に変換
        let hierarchyOrder = convertToHierarchyOrder()

        var lines: [String] = []

        for task in hierarchyOrder {
            let indent = String(repeating: indentUnit, count: task.indentLevel)
            let checkbox = task.isCompleted ? "[x]" : "[ ]"
            let priority = task.isRoot ? " \(task.priority.symbol)" : ""
            let pomodoros = task.pomodoros > 0 ? " (\(task.pomodoros)×)" : ""
            lines.append("\(indent)- \(checkbox) \(task.title)\(priority)\(pomodoros)")

            // notes は次のインデントレベルで bullet として書き出し
            if let notes = task.notes, !notes.isEmpty {
                let noteIndent = String(repeating: indentUnit, count: task.indentLevel + 1)
                for noteLine in notes.components(separatedBy: "\n") where !noteLine.isEmpty {
                    lines.append("\(noteIndent)- \(noteLine)")
                }
            }
        }

        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 実行順を階層順（親→サブタスク）に変換
    private func convertToHierarchyOrder() -> [TodoTask] {
        var result: [TodoTask] = []
        let roots = taskList.tasks.filter { $0.isRoot }

        func addWithChildren(_ task: TodoTask) {
            result.append(task)
            let children = taskList.tasks.filter { $0.parentId == task.id }
            for child in children {
                addWithChildren(child)
            }
        }

        for root in roots {
            addWithChildren(root)
        }

        // 孤立したサブタスク
        let addedIds = Set(result.map { $0.id })
        let orphans = taskList.tasks.filter { !addedIds.contains($0.id) }
        result.append(contentsOf: orphans)

        return result
    }

    // MARK: - Indent Detection

    /// インデント単位を自動検知（タブ or スペース数）
    private func detectIndentUnit(in text: String) -> IndentUnit {
        let lines = text.components(separatedBy: .newlines)

        // タブがあるかチェック
        for line in lines {
            if line.hasPrefix("\t") {
                return .tab
            }
        }

        // スペースの最小単位を検出
        var minSpaces = Int.max
        for line in lines {
            let spaces = line.prefix(while: { $0 == " " }).count
            if spaces > 0 && spaces < minSpaces {
                minSpaces = spaces
            }
        }

        return .spaces(minSpaces == Int.max ? 2 : minSpaces)
    }

    private enum IndentUnit {
        case tab
        case spaces(Int)
    }

    /// 行のインデントレベルを計算
    private func calculateIndentLevel(line: String, indentUnit: IndentUnit) -> Int {
        switch indentUnit {
        case .tab:
            return line.prefix(while: { $0 == "\t" }).count
        case .spaces(let count):
            let spaces = line.prefix(while: { $0 == " " }).count
            return count > 0 ? spaces / count : 0
        }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            taskList = try JSONDecoder().decode(TaskList.self, from: data)
        } catch {
            // 新しいフォーマットで読めない場合は空リストで開始
            taskList = TaskList()
        }
    }

    /// 保存されたタスクリストをリロード
    public func reload() {
        load()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(taskList)
            try data.write(to: storageURL)
        } catch {
            // エラーは無視
        }
    }

    // MARK: - Hierarchy Helpers

    /// 指定タスクの直接の子・孫含む未完了サブタスク数
    public func incompleteSubtaskCount(for taskId: String) -> Int {
        let subtaskIds = Set(getSubtaskIds(for: taskId))
        return taskList.tasks.filter { subtaskIds.contains($0.id) && !$0.isCompleted }.count
    }

    /// 指定タスクの全サブタスク（直接の子・孫含む）が完了しているか
    public func areAllSubtasksCompleted(for taskId: String) -> Bool {
        let subtaskIds = getSubtaskIds(for: taskId)
        guard !subtaskIds.isEmpty else { return true }
        return subtaskIds.allSatisfy { id in
            taskList.tasks.first(where: { $0.id == id })?.isCompleted ?? false
        }
    }

    /// 親タスクが存在し、その親の全サブタスクが完了したら親も自動完了
    /// 完了されたタスクのID（あれば）を返す
    @discardableResult
    public func autoCompleteParentIfReady(for taskId: String) -> String? {
        guard let task = taskList.tasks.first(where: { $0.id == taskId }),
              let parentId = task.parentId,
              let parentIndex = taskList.tasks.firstIndex(where: { $0.id == parentId }),
              !taskList.tasks[parentIndex].isCompleted,
              areAllSubtasksCompleted(for: parentId) else {
            return nil
        }
        // 親を完了
        taskList.tasks[parentIndex].isCompleted = true
        // 親も含めて末尾に並べ替え
        let parentTask = taskList.tasks.remove(at: parentIndex)
        taskList.tasks.append(parentTask)
        taskList.lastModified = Date()
        save()
        // 再帰的に祖父も判定
        autoCompleteParentIfReady(for: parentId)
        return parentId
    }

    /// 完了後に次の未完了タスクへ自動遷移（集中状態の保護）
    public func advanceToNextTask() {
        if let next = taskList.nextTask {
            currentTaskId = next.id
        }
    }

    /// Quick Capture: 軽量タスクを末尾に追加（ソート影響なし、低優先度）
    public func quickCapture(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let task = TodoTask(title: trimmed, priority: .low)
        // 未完了タスクの末尾、完了タスクの直前に挿入
        let insertIndex = taskList.tasks.firstIndex(where: { $0.isCompleted }) ?? taskList.tasks.count
        taskList.tasks.insert(task, at: insertIndex)
        taskList.lastModified = Date()
        save()
    }
}
