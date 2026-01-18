import Foundation

/// シンプルな優先度: ! !! !!!
public enum Priority: Int, Codable, CaseIterable, Sendable {
    case low = 1      // !
    case medium = 2   // !!
    case high = 3     // !!!

    public var symbol: String {
        switch self {
        case .low: return "!"
        case .medium: return "!!"
        case .high: return "!!!"
        }
    }
}

public struct TodoTask: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var priority: Priority
    public var isCompleted: Bool
    public var pomodoros: Int  // 実績ポモドーロ数
    public var createdAt: Date
    public var parentId: String?  // 親タスクのID（nilならルートタスク）
    public var indentLevel: Int   // インデントレベル（0=ルート）

    public init(
        id: String = UUID().uuidString,
        title: String,
        priority: Priority = .medium,
        isCompleted: Bool = false,
        pomodoros: Int = 0,
        createdAt: Date = Date(),
        parentId: String? = nil,
        indentLevel: Int = 0
    ) {
        self.id = id
        self.title = title
        self.priority = priority
        self.isCompleted = isCompleted
        self.pomodoros = pomodoros
        self.createdAt = createdAt
        self.parentId = parentId
        self.indentLevel = indentLevel
    }

    public mutating func complete() {
        isCompleted = true
    }

    public mutating func addPomodoro() {
        pomodoros += 1
    }

    /// ルートタスクかどうか
    public var isRoot: Bool {
        parentId == nil
    }
}
