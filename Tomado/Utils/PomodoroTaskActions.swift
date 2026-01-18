import Foundation

/// Pomodoro関連のタスク操作を統一するユーティリティクラス
@MainActor
public class PomodoroTaskActions {

    /// 現在のタスクをスキップする
    public static func skipCurrentTask(timer: PomodoroTimer) {
        guard let task = timer.currentTask else { return }

        let elapsedPomodoros = timer.getElapsedPomodoros()

        // 累積時間をクリア（二重記録を防ぐため）
        timer.clearAccumulatedTime(for: task.id)

        NotificationCenter.default.post(
            name: .taskUpdated,
            object: nil,
            userInfo: [
                "task": task,
                "source": "task_skipped",
                "elapsedPomodoros": elapsedPomodoros,
            ]
        )
    }

    /// 現在のタスクを完了する
    public static func completeCurrentTask(timer: PomodoroTimer) {
        guard let task = timer.currentTask else { return }

        let elapsedPomodoros = timer.getElapsedPomodoros()

        // 累積時間をクリア（二重記録を防ぐため）
        timer.clearAccumulatedTime(for: task.id)

        NotificationCenter.default.post(
            name: .taskUpdated,
            object: nil,
            userInfo: [
                "task": task,
                "source": "task_completed",
                "elapsedPomodoros": elapsedPomodoros,
            ]
        )
    }
}
