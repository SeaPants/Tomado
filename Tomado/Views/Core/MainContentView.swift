import SwiftUI

struct MainContentView: View {
    @ObservedObject var pomodoroTimer: PomodoroTimer
    @ObservedObject var taskListViewModel: TaskListViewModel

    var body: some View {
        FocusedMainView(
            timer: pomodoroTimer,
            taskListVM: taskListViewModel
        )
    }
}
