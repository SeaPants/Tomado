import Foundation

/// シンプルなタスクリスト
public struct TaskList: Codable {
    public var tasks: [TodoTask]
    public var lastModified: Date

    public init(tasks: [TodoTask] = [], lastModified: Date = Date()) {
        self.tasks = tasks
        self.lastModified = lastModified
    }

    /// 優先度順でソート（サブタスクは親と一緒に移動、実行順で並べる）
    /// 同じ優先度の場合は元の順序を維持（stable sort、ユーザの手動順序を尊重）
    /// ascending: falseなら優先度が高い順、trueなら低い順
    public mutating func sort(ascending: Bool = false) {
        let incomplete = tasks.filter { !$0.isCompleted }
        let completed = tasks.filter { $0.isCompleted }

        // ルートタスクをソート（同優先度時は元の順序を維持: indexed sort で stable に）
        let indexedRoots = incomplete.filter { $0.isRoot }.enumerated()
            .map { (index: $0.offset, task: $0.element) }
        let sortedRoots = indexedRoots
            .sorted { lhs, rhs in
                if lhs.task.priority.rawValue != rhs.task.priority.rawValue {
                    return ascending
                        ? lhs.task.priority.rawValue < rhs.task.priority.rawValue
                        : lhs.task.priority.rawValue > rhs.task.priority.rawValue
                }
                // tie: 元の順序を維持
                return lhs.index < rhs.index
            }
            .map { $0.task }

        // 各ルートタスクとそのサブタスクを実行順（サブタスク→親）で並べる
        var sorted: [TodoTask] = []
        for root in sortedRoots {
            let subtasks = getSubtasksInExecutionOrder(for: root.id, from: incomplete)
            sorted.append(contentsOf: subtasks)
            sorted.append(root)
        }

        // 孤立したサブタスク（親が完了済みなど）
        let orphans = incomplete.filter { task in
            !task.isRoot && !sorted.contains(where: { $0.id == task.id })
        }
        sorted.append(contentsOf: orphans)

        tasks = sorted + completed
        lastModified = Date()
    }

    /// 指定した親のサブタスクを実行順（深い順）で取得
    private func getSubtasksInExecutionOrder(for parentId: String, from tasks: [TodoTask]) -> [TodoTask] {
        let directChildren = tasks.filter { $0.parentId == parentId }
        var result: [TodoTask] = []

        for child in directChildren {
            // 再帰的に孫タスクを先に
            result.append(contentsOf: getSubtasksInExecutionOrder(for: child.id, from: tasks))
            result.append(child)
        }

        return result
    }

    /// 次のタスク（未完了の最初）
    public var nextTask: TodoTask? {
        tasks.first { !$0.isCompleted }
    }

    /// 統計
    public var stats: (completed: Int, total: Int, pomodoros: Int) {
        let completed = tasks.filter { $0.isCompleted }.count
        let total = tasks.count
        let pomodoros = tasks.reduce(0) { $0 + $1.pomodoros }
        return (completed, total, pomodoros)
    }
}
