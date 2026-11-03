import Foundation

/// 1 日を 15 分マス（96 個）に区切ったときの、計画ブロック 1 つ
public struct TimeBlock: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var taskId: String
    public var startSlot: Int  // 0 = 0:00〜0:15
    public var length: Int     // マス数（1 マス = 15 分）

    public init(id: String = UUID().uuidString, taskId: String, startSlot: Int, length: Int) {
        self.id = id
        self.taskId = taskId
        self.startSlot = startSlot
        self.length = length
    }

    public var endSlot: Int { startSlot + length }

    public func contains(_ slot: Int) -> Bool {
        slot >= startSlot && slot < endSlot
    }
}

/// カレンダーの予定で埋まっている時間帯（保存しない。毎回カレンダーから引く）
public struct BusyBlock: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let startSlot: Int
    public let endSlot: Int  // このマスは含まない

    public func contains(_ slot: Int) -> Bool {
        slot >= startSlot && slot < endSlot
    }
}

/// ある 1 日の計画（どのマスで何をやるつもりか）と実績（どのマスで何を何秒やったか）
public struct DayPlan: Codable, Equatable, Sendable {
    public static let slotMinutes = 15
    public static let slotsPerDay = 24 * 60 / slotMinutes

    public var day: String  // yyyy-MM-dd（ローカル時刻）
    public var blocks: [TimeBlock]
    public var worked: [Int: [String: Int]]  // slot -> taskId -> 実作業秒数

    public init(day: String, blocks: [TimeBlock] = [], worked: [Int: [String: Int]] = [:]) {
        self.day = day
        self.blocks = blocks
        self.worked = worked
    }

    public func block(at slot: Int) -> TimeBlock? {
        blocks.first { $0.contains(slot) }
    }

    /// そのマスで一番長く作業したタスク（実績の色付け用）
    public func dominantTask(at slot: Int) -> (taskId: String, seconds: Int)? {
        worked[slot]?.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    public var totalWorkedSeconds: Int {
        worked.values.reduce(0) { $0 + $1.values.reduce(0, +) }
    }

    public var totalPlannedSlots: Int {
        blocks.reduce(0) { $0 + $1.length }
    }

    // MARK: - Calendar helpers

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func slot(for date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return ((c.hour ?? 0) * 60 + (c.minute ?? 0)) / slotMinutes
    }

    /// "9:15" のようなマス開始時刻の表記
    public static func label(for slot: Int) -> String {
        let minutes = slot * slotMinutes
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
