import AppKit
import SwiftUI

@main
public struct TomadoApp: App {
    @StateObject private var pomodoroTimer = PomodoroTimer()
    @StateObject private var taskListViewModel = TaskListViewModel()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            MainContentView(
                pomodoroTimer: pomodoroTimer,
                taskListViewModel: taskListViewModel
            )
            .task {
                await initializeApp()
            }
            .frame(minWidth: 320, minHeight: 450)
        }
        .defaultSize(width: 360, height: 550)
        .windowResizability(.contentMinSize)
    }

    private func initializeApp() async {
        await MainActor.run {
            if let nextTask = taskListViewModel.taskList.nextTask {
                pomodoroTimer.setCurrentTask(nextTask)
            }
        }
    }
}
