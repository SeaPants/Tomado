import AppKit
import Foundation
import SwiftUI

@MainActor
public class TaskListViewModel: ObservableObject {
    @Published public var taskList: TaskList = TaskList()
    @Published public var currentTaskId: String?  // 現在選択中のタスクID

    private let storageURL: URL

    /// ソート前の手動順序スナップショット（ソート状態を解除したときに復元する）
    private static let manualOrderKey = "manualTaskOrder"

    /// タイマーから届く端数ポモドーロを蓄積し、1.0 を超えたら実績に繰り上げる
    private var fractionalPomodoros: [String: Double] = [:]

    public init() {
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDir = appSupportURL.appendingPathComponent("com.tomado.app", isDirectory: true)
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.storageURL = appDir.appendingPathComponent("tasks.json")
        load()
        observePomodoroProgress()
    }

    /// タイマーが記録した作業時間をタスクの実績ポモドーロに反映する
    /// （ViewModel はアプリと同じ寿命なので明示的な removeObserver は不要）
    private func observePomodoroProgress() {
        NotificationCenter.default.addObserver(
            forName: .pomodoroProgressByTaskId, object: nil, queue: .main
        ) { [weak self] note in
            guard let taskId = note.userInfo?["taskId"] as? String,
                  let amount = note.userInfo?["elapsedPomodoros"] as? Double else { return }
            Task { @MainActor in
                self?.addPomodoroProgress(amount, toTaskId: taskId)
            }
        }
    }

    /// 端数を含む進捗を加算し、1ポモドーロ分たまるごとに実績を +1 する
    public func addPomodoroProgress(_ amount: Double, toTaskId taskId: String) {
        guard amount > 0, taskList.tasks.contains(where: { $0.id == taskId }) else { return }

        let accumulated = (fractionalPomodoros[taskId] ?? 0) + amount
        // 浮動小数の誤差で 0.99999… が 0 に落ちないよう、ごく小さい許容を足す
        let whole = Int(accumulated + 1e-9)
        fractionalPomodoros[taskId] = accumulated - Double(whole)

        guard whole > 0, let index = taskList.tasks.firstIndex(where: { $0.id == taskId }) else { return }
        taskList.tasks[index].pomodoros += whole
        taskList.lastModified = Date()
        save()
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
    /// 挿入先は対象ルートの「サブツリー先頭」なので、他タスクのサブツリー内部には入り込まない
    private func findInsertIndex(for priority: Priority) -> Int {
        for task in taskList.tasks where !task.isCompleted && task.isRoot {
            if task.priority.rawValue < priority.rawValue {
                return subtreeStartIndex(of: task.id) ?? taskList.tasks.count
            }
        }
        // 未完了タスクの末尾（完了タスクの直前）
        return endOfIncompleteIndex()
    }

    /// 未完了タスクの直後（＝完了ブロックの先頭）の index
    /// 「完了タスクは末尾に固まっている」という前提に依存しないので、順序が乱れていても安全
    private func endOfIncompleteIndex() -> Int {
        taskList.tasks.lastIndex(where: { !$0.isCompleted }).map { $0 + 1 } ?? 0
    }

    /// 指定タスクのサブツリー（本人＋子孫）が配列内で最初に現れる位置
    private func subtreeStartIndex(of taskId: String) -> Int? {
        let ids = Set(getSubtaskIds(for: taskId) + [taskId])
        return taskList.tasks.firstIndex { ids.contains($0.id) }
    }

    /// サブツリーを実行順（深い子孫 → 本人）で構築
    private func subtreeInExecutionOrder(_ taskId: String) -> [TodoTask] {
        var result: [TodoTask] = []
        for child in taskList.tasks where child.parentId == taskId {
            result.append(contentsOf: subtreeInExecutionOrder(child.id))
        }
        if let task = taskList.tasks.first(where: { $0.id == taskId }) {
            result.append(task)
        }
        return result
    }

    /// サブツリーを一塊のまま配列内で移動する
    /// - Parameter resolveIndex: 移動対象を取り除いた後の配列における挿入位置を返す
    private func relocateSubtree(_ taskId: String, insertingAt resolveIndex: () -> Int) {
        let block = subtreeInExecutionOrder(taskId)
        guard !block.isEmpty else { return }
        let ids = Set(block.map { $0.id })
        taskList.tasks.removeAll { ids.contains($0.id) }

        let insertAt = resolveIndex()
        taskList.tasks.insert(contentsOf: block, at: min(max(insertAt, 0), taskList.tasks.count))
    }

    /// 対象タスクの「サブツリー先頭」の直前へ移動する（＝表示上その行の真上に来る）
    private func relocateSubtree(_ taskId: String, above anchorId: String?) {
        relocateSubtree(taskId) {
            anchorId.flatMap { subtreeStartIndex(of: $0) } ?? endOfIncompleteIndex()
        }
    }

    /// 親タスク「そのもの」の直前へ移動する（＝既存の兄弟より後ろ、実行順で末子になる）
    private func relocateSubtree(_ taskId: String, asLastChildOf parentId: String) {
        relocateSubtree(taskId) {
            taskList.tasks.firstIndex { $0.id == parentId } ?? endOfIncompleteIndex()
        }
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
        let insertIndex = updatedTasks.lastIndex(where: { !$0.isCompleted }).map { $0 + 1 } ?? 0
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
        guard taskId != parentId,
              taskList.tasks.contains(where: { $0.id == taskId }),
              taskList.tasks.contains(where: { $0.id == parentId }) else { return }

        // 循環参照チェック（親が自分の子孫でないことを確認）
        if isDescendant(parentId, of: taskId) { return }

        reparent(taskId, to: parentId)
        // 親の直前にサブツリーごと移動（実行順: サブタスク → 親）。
        // 既にいる兄弟の後ろに付ける＝ドロップした順に上から並ぶ
        relocateSubtree(taskId, asLastChildOf: parentId)

        invalidateManualOrder()
        taskList.lastModified = Date()
        save()
    }

    /// タスクの親を付け替え、自分と子孫のインデントレベルを整える（配列順は動かさない）
    /// - Parameter newParentId: nil ならルート化
    private func reparent(_ taskId: String, to newParentId: String?) {
        guard let index = taskList.tasks.firstIndex(where: { $0.id == taskId }) else { return }

        if let newParentId, let parent = taskList.tasks.first(where: { $0.id == newParentId }) {
            let newLevel = parent.indentLevel + 1
            taskList.tasks[index].parentId = newParentId
            taskList.tasks[index].indentLevel = newLevel
            updateDescendantIndentLevels(for: taskId, baseLevel: newLevel)
        } else {
            let oldLevel = taskList.tasks[index].indentLevel
            taskList.tasks[index].parentId = nil
            taskList.tasks[index].indentLevel = 0
            adjustDescendantLevels(for: taskId, levelDiff: -oldLevel)
        }
    }

    /// 指定タスクが別タスクの子孫かどうかをチェック（データが循環していても停止する）
    private func isDescendant(_ taskId: String, of ancestorId: String) -> Bool {
        var current = taskId
        var visited: Set<String> = []
        while let task = taskList.tasks.first(where: { $0.id == current }) {
            if task.parentId == ancestorId { return true }
            guard let parentId = task.parentId, visited.insert(current).inserted else { break }
            current = parentId
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
        guard let task = taskList.tasks.first(where: { $0.id == taskId }), !task.isRoot else { return }

        // 元の親の直前に居座らせる（＝元居た場所にそのまま浮上させる）
        let anchorId = task.parentId
        reparent(taskId, to: nil)
        relocateSubtree(taskId, above: anchorId)

        invalidateManualOrder()
        taskList.lastModified = Date()
        save()
    }

    /// D&D 用: タスクを対象の直前へ移動し、同時に階層（親）も付け替える
    /// - Parameters:
    ///   - targetId: この タスクの直前に挿入する。nil なら未完了リストの末尾
    ///   - newParentId: 付け替え先の親。nil ならルートタスクに引き上げる
    public func moveTask(_ taskId: String, before targetId: String?, newParentId: String?) {
        guard taskList.tasks.contains(where: { $0.id == taskId }) else { return }
        // 移動先が自分自身・自分の子孫なら不正
        if let newParentId {
            guard newParentId != taskId,
                  taskList.tasks.contains(where: { $0.id == newParentId }),
                  !isDescendant(newParentId, of: taskId) else { return }
        }
        // 自分の子孫の前には入れない（サブツリーごと動くので位置が破綻する）
        if let targetId, targetId == taskId || isDescendant(targetId, of: taskId) { return }

        reparent(taskId, to: newParentId)
        relocateSubtree(taskId, above: targetId)

        invalidateManualOrder()
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
    /// 親が完了済み/存在しない未完了タスクも表示の起点にするので、どのタスクも画面から消えない
    public func tasksInHierarchyOrder() -> [TodoTask] {
        var result: [TodoTask] = []
        var added: Set<String> = []

        func addWithChildren(_ task: TodoTask) {
            guard added.insert(task.id).inserted else { return }
            result.append(task)
            for child in taskList.tasks where child.parentId == task.id && !child.isCompleted {
                addWithChildren(child)
            }
        }

        // 表示の起点: 未完了で、かつ親が居ない / 完了済み / 存在しない（＝親の下に描画されない）タスク
        for task in taskList.tasks where !task.isCompleted {
            let hasVisibleParent = taskList.tasks
                .first { $0.id == task.parentId }
                .map { !$0.isCompleted } ?? false
            if !hasVisibleParent {
                addWithChildren(task)
            }
        }

        // 循環参照などで取り残された未完了タスクの救済
        for task in taskList.tasks where !task.isCompleted && !added.contains(task.id) {
            added.insert(task.id)
            result.append(task)
        }

        return result
    }

    /// 階層順（親→子）で全タスク（完了/未完了混合）を取得
    public func allTasksInHierarchyOrder() -> [TodoTask] {
        var result: [TodoTask] = []
        var added: Set<String> = []

        func addWithChildren(_ task: TodoTask) {
            guard added.insert(task.id).inserted else { return }
            result.append(task)
            for child in taskList.tasks where child.parentId == task.id {
                addWithChildren(child)
            }
        }

        // 親が存在しないタスク（宙ぶらりんの parentId を含む）を起点にする
        for task in taskList.tasks where !taskList.tasks.contains(where: { $0.id == task.parentId }) {
            addWithChildren(task)
        }

        // 循環参照などで取り残されたタスクの救済
        for task in taskList.tasks where !added.contains(task.id) {
            added.insert(task.id)
            result.append(task)
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
    /// 対象と同じ階層に揃えるので、ルートの前に落とせばサブタスクは自動的にルートへ引き上がる
    public func insertTask(_ taskId: String, before targetId: String) {
        guard let target = taskList.tasks.first(where: { $0.id == targetId }) else { return }
        moveTask(taskId, before: targetId, newParentId: target.parentId)
    }

    /// タスクを未完了リストの末尾へ移動し、ルートタスクに引き上げる（リスト下端へのドロップ用）
    public func moveTaskToEndAsRoot(_ taskId: String) {
        moveTask(taskId, before: nil, newParentId: nil)
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
    /// 最初のソート前に手動順序を控えておき、あとで復元できるようにする
    public func sort(ascending: Bool = false) {
        if UserDefaults.standard.array(forKey: Self.manualOrderKey) == nil {
            UserDefaults.standard.set(taskList.tasks.map { $0.id }, forKey: Self.manualOrderKey)
        }
        taskList.sort(ascending: ascending)
        save()
    }

    /// ソート前の手動順序へ戻す（控えが無ければ何もしない）
    /// - Returns: 実際に復元したら true
    @discardableResult
    public func restoreManualOrder() -> Bool {
        guard let savedIds = UserDefaults.standard.array(forKey: Self.manualOrderKey) as? [String] else {
            return false
        }
        UserDefaults.standard.removeObject(forKey: Self.manualOrderKey)

        var remaining = taskList.tasks
        var restored: [TodoTask] = []
        for id in savedIds {
            if let index = remaining.firstIndex(where: { $0.id == id }) {
                restored.append(remaining.remove(at: index))
            }
        }
        // 控えを取ったあとに追加されたタスクは末尾に残す
        restored.append(contentsOf: remaining)

        // 控えを取った後に完了したタスクがあるので、「完了は末尾」の不変条件を張り直す
        restored = restored.filter { !$0.isCompleted } + restored.filter { $0.isCompleted }

        taskList = TaskList(tasks: restored, lastModified: Date())
        save()
        return true
    }

    /// 手動で並びを変えたら、ソート前の控えは意味を失うので破棄する
    private func invalidateManualOrder() {
        UserDefaults.standard.removeObject(forKey: Self.manualOrderKey)
    }

    /// 全クリア
    public func clearAll() {
        taskList.tasks.removeAll()
        invalidateManualOrder()
        taskList.lastModified = Date()
        save()
    }

    /// 完了タスクのみクリア（生き残るサブタスクは親を失うのでルートに引き上げる）
    public func clearCompleted() {
        let removedIds = Set(taskList.tasks.filter { $0.isCompleted }.map { $0.id })
        guard !removedIds.isEmpty else { return }

        taskList.tasks.removeAll { removedIds.contains($0.id) }

        // 消えた親を指したままだと、どのビューからも辿れない幽霊タスクになる
        for index in taskList.tasks.indices {
            if let parentId = taskList.tasks[index].parentId, removedIds.contains(parentId) {
                let oldLevel = taskList.tasks[index].indentLevel
                taskList.tasks[index].parentId = nil
                taskList.tasks[index].indentLevel = 0
                adjustDescendantLevels(for: taskList.tasks[index].id, levelDiff: -oldLevel)
            }
        }

        invalidateManualOrder()
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

    /// インポート結果。skipped は重複とみなして捨てた件数
    public struct ImportResult: Sendable {
        public let added: Int
        public let skipped: Int
    }

    /// クリップボードからインポート（階層構造対応）
    public func importFromClipboard() -> ImportResult {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            return ImportResult(added: 0, skipped: 0)
        }
        let lines = text.components(separatedBy: .newlines)

        // 設定を取得
        let allowListFormat = UserDefaults.standard.bool(forKey: "importAllowListFormat")

        // インデント自動検知: スペース1レベルぶんの幅（タブは常に1レベル）
        let spacesPerLevel = detectSpacesPerLevel(in: text)

        // パース結果を一時保存
        enum ParsedItem {
            case task(title: String, priority: Priority, isCompleted: Bool, pomodoros: Int, indentLevel: Int)
            case note(text: String, indentLevel: Int)
        }

        var parsed: [ParsedItem] = []

        for line in lines {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let indentLevel = calculateIndentLevel(line: line, spacesPerLevel: spacesPerLevel)
            var content = line.trimmingCharacters(in: .whitespaces)

            // Markdown チェックボックス形式をタスクとしてパース（`- ` と `* ` の両方を受け付ける）
            var isTask = false
            var isCompleted = false
            // 末尾を `)` で閉じる: 正規表現リテラルは `*/` で終われない（ブロックコメント終端と衝突）
            if let match = content.firstMatch(of: /^[-*]\s+\[([ xX])\](\s*)/) {
                isCompleted = match.1 != " "
                content = String(content[match.range.upperBound...]).trimmingCharacters(in: .whitespaces)
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

            // 実績ポモドーロ数をパース（エクスポートの " (3×)" 形式）— 優先度より先に外す
            var pomodoros = 0
            if let match = content.firstMatch(of: /\s*\((\d+)[×x]\)$/) {
                pomodoros = Int(match.1) ?? 0
                content = String(content[..<match.range.lowerBound])
            }

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

            content = content.trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }

            parsed.append(.task(
                title: content, priority: priority, isCompleted: isCompleted,
                pomodoros: pomodoros, indentLevel: indentLevel
            ))
        }

        guard !parsed.isEmpty else { return ImportResult(added: 0, skipped: 0) }

        // 親子関係を構築しながらタスク + メモを実体化
        var parentStack: [(level: Int, id: String, actualIndent: Int)] = []
        var addedTasks: [TodoTask] = []
        var notesByTaskId: [String: [String]] = [:]
        var lastTaskId: String?
        var lastTaskLevel: Int = -1

        for item in parsed {
            switch item {
            case let .task(title, priority, isCompleted, pomodoros, indentLevel):
                while !parentStack.isEmpty && parentStack.last!.level >= indentLevel {
                    parentStack.removeLast()
                }
                let parentId = parentStack.last?.id
                let actualIndentLevel = parentStack.last.map { $0.actualIndent + 1 } ?? 0

                let task = TodoTask(
                    title: title,
                    priority: priority,
                    isCompleted: isCompleted,
                    pomodoros: pomodoros,
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

        // 未完了の子を持つ親は完了扱いにしない（完了親＋未完了子はどのビューでも辿れなくなる）
        var hasIncompleteChild: Set<String> = []
        for task in addedTasks where !task.isCompleted {
            var cursor = task.parentId
            while let parentId = cursor, hasIncompleteChild.insert(parentId).inserted {
                cursor = addedTasks.first { $0.id == parentId }?.parentId
            }
        }
        for i in addedTasks.indices where hasIncompleteChild.contains(addedTasks[i].id) {
            addedTasks[i].isCompleted = false
        }

        // 同じ親の下で同名・同優先度の未完了タスクは同じものとみなして捨てる
        let skipped = addedTasks.count
        addedTasks = dropDuplicates(in: addedTasks)
        let skippedCount = skipped - addedTasks.count
        guard !addedTasks.isEmpty else {
            return ImportResult(added: 0, skipped: skippedCount)
        }

        // 表示順（親→子）でパースしたものを、保存フォーマットである実行順（子→親）に並べ替える
        let ordered = inExecutionOrder(addedTasks)

        // 完了/未完了それぞれ正しいブロックに入れて「完了は末尾」という不変条件を保つ
        let incoming = ordered.filter { !$0.isCompleted }
        let incomingCompleted = ordered.filter { $0.isCompleted }
        taskList.tasks.insert(contentsOf: incoming, at: endOfIncompleteIndex())
        taskList.tasks.append(contentsOf: incomingCompleted)

        // 手動順序の控えは破棄しない。追加分は控えに載っていないだけで、
        // restoreManualOrder() が末尾に回してくれる（ここで捨てると復元できなくなる）
        taskList.lastModified = Date()
        save()

        return ImportResult(added: addedTasks.count, skipped: skippedCount)
    }

    /// 重複判定のキー。「同じ親の下の、同じタイトル・同じ優先度」だけを同一視する
    private struct SiblingKey: Hashable {
        let parentId: String?
        let title: String
        let priority: Int
    }

    /// インポート分から重複を落とす。
    /// - 既存リストとは未完了タスク同士だけを比べる（完了済みは再追加を邪魔しない）
    /// - 親が違えば別物。インポート分のサブタスクは親 id が新規なので、
    ///   突き合わせが成立するのはルート同士とバッチ内の兄弟同士だけになる
    /// - 親を捨てるときはサブツリーごと捨てる（子だけ残すと親のいない迷子になる）
    /// - `incoming` は親が子より先に並んでいる前提（パース順＝表示順）
    private func dropDuplicates(in incoming: [TodoTask]) -> [TodoTask] {
        var seen = Set(
            taskList.tasks
                .filter { !$0.isCompleted }
                .map { SiblingKey(parentId: $0.parentId, title: $0.title, priority: $0.priority.rawValue) }
        )
        var droppedIds = Set<String>()
        var kept: [TodoTask] = []

        for task in incoming {
            if let parentId = task.parentId, droppedIds.contains(parentId) {
                droppedIds.insert(task.id)
                continue
            }
            if !task.isCompleted {
                let key = SiblingKey(
                    parentId: task.parentId, title: task.title, priority: task.priority.rawValue
                )
                guard seen.insert(key).inserted else {
                    droppedIds.insert(task.id)
                    continue
                }
            }
            kept.append(task)
        }
        return kept
    }

    /// 親→子の並びを、保存フォーマットである実行順（子孫 → 本人）へ変換する
    private func inExecutionOrder(_ tasks: [TodoTask]) -> [TodoTask] {
        var result: [TodoTask] = []

        func append(_ task: TodoTask) {
            for child in tasks where child.parentId == task.id {
                append(child)
            }
            result.append(task)
        }

        for task in tasks where task.parentId == nil {
            append(task)
        }
        // 親がこのバッチに居ないタスクの取りこぼしを防ぐ
        let addedIds = Set(result.map { $0.id })
        result.append(contentsOf: tasks.filter { !addedIds.contains($0.id) })
        return result
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
            // 優先度はサブタスクにも書き出す（書かないと再インポートで medium に潰れる）
            let priority = " \(task.priority.symbol)"
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
        allTasksInHierarchyOrder()
    }

    // MARK: - Indent Detection

    /// スペース1レベルぶんの幅を自動検知する
    /// タブは常に1レベルとして扱うので、タブとスペースが混在していても階層は潰れない
    private func detectSpacesPerLevel(in text: String) -> Int {
        var minSpaces = Int.max
        for line in text.components(separatedBy: .newlines) {
            let spaces = line.drop(while: { $0 == "\t" }).prefix(while: { $0 == " " }).count
            if spaces > 0 {
                minSpaces = min(minSpaces, spaces)
            }
        }
        return minSpaces == Int.max ? 2 : minSpaces
    }

    /// 行のインデントレベルを計算（タブ = 1レベル、スペース = 検出した単位ごとに1レベル）
    private func calculateIndentLevel(line: String, spacesPerLevel: Int) -> Int {
        var tabs = 0
        var spaces = 0
        for character in line {
            if character == "\t" {
                tabs += 1
            } else if character == " " {
                spaces += 1
            } else {
                break
            }
        }
        return tabs + spaces / max(spacesPerLevel, 1)
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            taskList = try JSONDecoder().decode(TaskList.self, from: data)
        } catch {
            // 読めない場合は空リストで開始するが、元データは退避して救出可能にしておく
            let backupURL = storageURL.deletingLastPathComponent()
                .appendingPathComponent("tasks.corrupt.json")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: storageURL, to: backupURL)
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
            // .atomic: 書き込み途中で落ちても tasks.json が切り詰められない
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // エラーは無視
        }
    }

    // MARK: - Hierarchy Helpers

    /// 指定タスクの全サブタスク数（完了/未完了問わず、孫以下も含む）
    public func subtaskCount(for taskId: String) -> Int {
        getSubtaskIds(for: taskId).count
    }

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
        taskList.tasks.insert(task, at: endOfIncompleteIndex())
        taskList.lastModified = Date()
        save()
    }

    /// タスクの優先度を変更して保存する（View から直接 tasks を書き換えると保存されない）
    public func setPriority(_ priority: Priority, forTaskId taskId: String) {
        guard let index = taskList.tasks.firstIndex(where: { $0.id == taskId }),
              taskList.tasks[index].priority != priority else { return }
        taskList.tasks[index].priority = priority
        taskList.lastModified = Date()
        save()
    }
}
