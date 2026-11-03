import SwiftUI

struct MainContentView: View {
    @ObservedObject var pomodoroTimer: PomodoroTimer
    @ObservedObject var taskListViewModel: TaskListViewModel
    @ObservedObject var dayPlanner: DayPlanner

    var body: some View {
        FocusedMainView(
            timer: pomodoroTimer,
            taskListVM: taskListViewModel,
            planner: dayPlanner
        )
    }
}
