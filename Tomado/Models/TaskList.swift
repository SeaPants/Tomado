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
    /// ascending: falseなら優先度が高い順、trueなら低い順
    public mutating func sort(ascending: Bool = false) {
        let incomplete = tasks.filter { !$0.isCompleted }
        let completed = tasks.filter { $0.isCompleted }

        // ルートタスクをソート
        let sortedRoots = incomplete.filter { $0.isRoot }
            .sorted { root1, root2 in
                // 優先度が違えば優先度順
                if root1.priority.rawValue != root2.priority.rawValue {
                    return ascending
                        ? root1.priority.rawValue < root2.priority.rawValue
                        : root1.priority.rawValue > root2.priority.rawValue
                }
                // 同じ優先度ならサブタスク数が少ない順（早く終わる順）
                let subtaskCount1 = countAllSubtasks(for: root1.id, from: incomplete)
                let subtaskCount2 = countAllSubtasks(for: root2.id, from: incomplete)
                return subtaskCount1 < subtaskCount2
            }

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

    /// 指定タスクの全サブタスク数を再帰的にカウント
    private func countAllSubtasks(for parentId: String, from tasks: [TodoTask]) -> Int {
        let directChildren = tasks.filter { $0.parentId == parentId }
        var count = directChildren.count
        for child in directChildren {
            count += countAllSubtasks(for: child.id, from: tasks)
        }
        return count
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
