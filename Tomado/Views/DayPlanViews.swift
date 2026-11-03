import EventKit
import SwiftUI

/// タスクごとの色。隣り合うブロックが同じ優先度でも見分けられるよう、優先度ではなく ID から決める
/// （String.hashValue は起動ごとに変わるので、自前の決定的なハッシュを使う）
enum TaskTint {
    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]

    static func color(for taskId: String) -> Color {
        var hash: UInt64 = 5381
        for byte in taskId.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

enum DayPlanFormat {
    /// 秒数を "1:20" / "45m" のような短い表記にする
    static func duration(seconds: Int) -> String {
        let minutes = seconds / 60
        return minutes >= 60 ? String(format: "%d:%02d", minutes / 60, minutes % 60) : "\(minutes)m"
    }
}

// MARK: - Strip

/// タイマー帯の下に置く、今日を 15 分マスで 1 行に並べた帯
/// 薄い色が計画、濃い色が実績。今のマスには枠を付ける
struct DayStripView: View {
    @ObservedObject var planner: DayPlanner
    @ObservedObject var taskListVM: TaskListViewModel
    var onTogglePanel: () -> Void

    static let height: CGFloat = 40

    var body: some View {
        let range = planner.visibleSlots
        VStack(spacing: 3) {
            headerLine
                .frame(height: 14)

            GeometryReader { geo in
                let cell = geo.size.width / CGFloat(range.count)
                HStack(spacing: 0) {
                    ForEach(Array(range), id: \.self) { slot in
                        cellView(slot)
                            .frame(width: cell)
                    }
                }
            }
            .frame(height: 8)

            GeometryReader { geo in
                let cell = geo.size.width / CGFloat(range.count)
                ForEach(Array(range).filter { $0 % 12 == 0 }, id: \.self) { slot in
                    Text("\(slot / 4)")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6))
                        .position(x: CGFloat(slot - range.lowerBound) * cell + 4, y: 4)
                }
            }
            .frame(height: 8)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .onTapGesture { onTogglePanel() }
        .help(String(localized: "planner.toggle"))
    }

    @ViewBuilder
    private var headerLine: some View {
        if let (block, task) = planner.suggestion(
            currentTaskId: taskListVM.currentTask?.id, tasks: taskListVM.taskList.tasks
        ).map({ ($0.block, $0.task) }) {
            HStack(spacing: 6) {
                Circle().fill(TaskTint.color(for: task.id)).frame(width: 6, height: 6)
                Text(String(localized: "planner.suggestion \(task.title)"))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(String(localized: "planner.switch")) {
                    taskListVM.selectTask(id: task.id)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                Button {
                    planner.dismissSuggestion(blockId: block.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .font(.system(size: 10, weight: .medium))
        } else {
            HStack {
                Text(String(localized: "planner.summary \(DayPlanFormat.duration(seconds: planner.plan.totalWorkedSeconds)) \(DayPlanFormat.duration(seconds: planner.plan.totalPlannedSlots * DayPlan.slotMinutes * 60))"))
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary.opacity(0.7))
        }
    }

    private func cellView(_ slot: Int) -> some View {
        let plan = planner.plan
        let worked = plan.dominantTask(at: slot)
        let isNow = slot == planner.currentSlot
        let isPast = slot < planner.currentSlot
        // 計画 > カレンダーの予定（濃い灰色）> 空き の順に背景を決める
        let background: Color =
            plan.block(at: slot).map { TaskTint.color(for: $0.taskId).opacity(0.3) }
            ?? (planner.isBusy(slot) ? Color.primary.opacity(0.28) : Color.primary.opacity(isPast ? 0.04 : 0.08))

        return ZStack {
            RoundedRectangle(cornerRadius: 1)
                .fill(background)
            if let worked {
                // 15 分のうちどれだけ作業したかを濃さで出す（少しでもやったら見えるよう下限を置く）
                RoundedRectangle(cornerRadius: 1)
                    .fill(TaskTint.color(for: worked.taskId)
                        .opacity(0.35 + 0.65 * min(1, Double(worked.seconds) / 900)))
            }
            if isNow {
                RoundedRectangle(cornerRadius: 1)
                    .stroke(Color.primary.opacity(0.7), lineWidth: 1)
            }
        }
        .padding(.horizontal, 0.5)
    }
}

// MARK: - Panel

/// 右に引き出す、今日の 15 分刻みタイムライン
/// 一覧からタスクをドラッグして置き、ブロックをドラッグで移動、下端で長さを変える
struct DayPlannerPanel: View {
    @ObservedObject var planner: DayPlanner
    @ObservedObject var taskListVM: TaskListViewModel
    var onClose: () -> Void

    static let width: CGFloat = 220
    private static let rowHeight: CGFloat = 18

    init(planner: DayPlanner, taskListVM: TaskListViewModel, onClose: @escaping () -> Void) {
        self.planner = planner
        self.taskListVM = taskListVM
        self.onClose = onClose
        // 前回閉じたときの位置。このセッションで初めて開くなら、今の少し前から
        initialTopSlot = planner.panelTopSlot ?? max(planner.visibleSlots.lowerBound, planner.currentSlot - 4)
    }
    private static let labelWidth: CGFloat = 34
    /// ブロックを横にこれだけ引きずり出したら「外へ捨てる」とみなす
    private static let discardDistance: CGFloat = 70

    private let initialTopSlot: Int  // 開いたときに一番上に出すマス
    @State private var topSlot: Int?  // いま一番上に見えているマス（スクロールの追跡用）
    private static let verticalPadding: CGFloat = 6
    @State private var isDropTargeted = false
    @State private var dragOffset: [String: CGSize] = [:]  // 移動中ブロックのずれ
    @State private var resizeOffset: [String: CGFloat] = [:]  // 伸縮中ブロックの長さの変化
    @State private var resizeHoverId: String?  // 伸縮つまみのカーソルを出しているブロック

    var body: some View {
        // 中身は常に全幅で描き、見えている幅だけ切り取る。開閉でウィンドウが伸び縮みする間、
        // 中身を潰さずに右から引き出し・引っ込めて見せるため
        HStack(spacing: 0) {
            Divider()
            content
                .frame(width: Self.width)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        }
        // 最小幅は 0 にしておく。固定幅にするとホスティングビューの最小幅に「パネル込み」が残り、
        // 閉じるときにウィンドウが縮みきらず、開閉のたびに幅が増えていく。
        // 開いている間の最小幅はウィンドウ側（contentMinSize）で守る
        .frame(minWidth: 0, idealWidth: Self.width + 1, maxWidth: Self.width + 1, alignment: .leading)
        .clipped()
        .layoutPriority(1)
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // 開いた瞬間から前回の位置で出す。開いてから scrollTo すると先頭から動いて見え、
            // scrollPosition(id:) の初期値は（Lazy でないスタックでは）効かないので、
            // 初期位置は defaultScrollAnchor で決める。scrollPosition は位置を覚えるためだけに使う
            GeometryReader { geo in
                ScrollView {
                    timeline
                        .padding(.vertical, Self.verticalPadding)
                }
                .defaultScrollAnchor(initialAnchor(viewportHeight: geo.size.height))
                .scrollPosition(id: $topSlot, anchor: .top)
                .onChange(of: topSlot) { _, slot in
                    if let slot { planner.panelTopSlot = slot }
                }
            }
        }
    }

    /// initialTopSlot が一番上に来る anchor。anchor の y は「スクロールできる量のうちどこか」の割合
    private func initialAnchor(viewportHeight: CGFloat) -> UnitPoint {
        let range = planner.visibleSlots
        let contentHeight = CGFloat(range.count) * Self.rowHeight + Self.verticalPadding * 2
        let scrollable = contentHeight - viewportHeight
        guard scrollable > 0 else { return .top }
        let offset = CGFloat(initialTopSlot - range.lowerBound) * Self.rowHeight
        return UnitPoint(x: 0, y: min(1, max(0, offset / scrollable)))
    }

    private var header: some View {
        HStack {
            Text(String(localized: "planner.title"))
                .font(.system(size: 12, weight: .semibold))
            Text(planner.plan.day)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "sidebar.right").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help(String(localized: "planner.toggle"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var timeline: some View {
        let range = planner.visibleSlots
        let height = CGFloat(range.count) * Self.rowHeight
        return ZStack(alignment: .topLeading) {
            // 罫線と時刻
            VStack(spacing: 0) {
                ForEach(Array(range), id: \.self) { slot in
                    gridRow(slot)
                        .frame(height: Self.rowHeight)
                        .id(slot)
                }
            }
            .scrollTargetLayout()

            ForEach(planner.busy) { event in
                if range.contains(event.startSlot) || range.contains(event.endSlot - 1) {
                    busyView(event, range: range)
                }
            }

            ForEach(planner.plan.blocks) { block in
                if let task = taskListVM.taskList.tasks.first(where: { $0.id == block.taskId }),
                   range.contains(block.startSlot) {
                    blockView(block, task: task, range: range)
                }
            }

            nowLine(range: range)

            if planner.plan.blocks.isEmpty {
                Text(String(localized: "planner.empty"))
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, CGFloat(max(0, planner.currentSlot - range.lowerBound)) * Self.rowHeight + 24)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height, alignment: .top)
        .padding(.horizontal, 8)
        .background(isDropTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
        .dropDestination(for: String.self) { ids, location in
            guard let taskId = ids.first,
                  taskListVM.taskList.tasks.contains(where: { $0.id == taskId }) else { return false }
            return planner.place(taskId: taskId, at: slot(at: location.y, range: range))
        } isTargeted: { isDropTargeted = $0 }
    }

    private func gridRow(_ slot: Int) -> some View {
        let isHour = slot % 4 == 0
        let workedSeconds = planner.plan.worked[slot]?.values.reduce(0, +) ?? 0
        return HStack(spacing: 4) {
            Text(isHour ? DayPlan.label(for: slot) : "")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary.opacity(slot < planner.currentSlot ? 0.4 : 0.8))
                .frame(width: Self.labelWidth - 4, alignment: .trailing)
            // 実績: マスの左端に、作業した割合だけ伸びる細い棒
            GeometryReader { geo in
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.primary.opacity(isHour ? 0.15 : 0.06))
                        .frame(height: 0.5)
                    Spacer(minLength: 0)
                }
                if let worked = planner.plan.dominantTask(at: slot) {
                    Capsule()
                        .fill(TaskTint.color(for: worked.taskId))
                        .frame(width: 3, height: max(2, geo.size.height * min(1, Double(workedSeconds) / 900)))
                        .offset(y: 1)
                }
            }
        }
    }

    private func blockView(_ block: TimeBlock, task: TodoTask, range: Range<Int>) -> some View {
        let tint = TaskTint.color(for: task.id)
        let baseHeight = CGFloat(block.length) * Self.rowHeight
        let height = max(Self.rowHeight, baseHeight + (resizeOffset[block.id] ?? 0)) - 2
        let drag = dragOffset[block.id] ?? .zero
        let y = CGFloat(block.startSlot - range.lowerBound) * Self.rowHeight + 1 + drag.height
        let isCurrent = taskListVM.currentTask?.id == task.id
        let willDiscard = abs(drag.width) > Self.discardDistance

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if isCurrent {
                    Image(systemName: "play.fill").font(.system(size: 7))
                }
                Text(task.title)
                    .font(.system(size: 10, weight: .medium))
                    .strikethrough(task.isCompleted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(DayPlanFormat.duration(seconds: block.length * DayPlan.slotMinutes * 60))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
            Spacer(minLength: 0)
            // 下端のつまみ: 引っ張ると 15 分単位で伸び縮みする
            Rectangle()
                .fill(Color.clear)
                .frame(height: 5)
                .contentShape(Rectangle())
                .onHover { inside in
                    // push と pop を必ず対にする（入らずに出たときに他のカーソルを剥がさない）
                    if inside, resizeHoverId == nil {
                        resizeHoverId = block.id
                        NSCursor.resizeUpDown.push()
                    } else if !inside, resizeHoverId == block.id {
                        resizeHoverId = nil
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { resizeOffset[block.id] = $0.translation.height }
                        .onEnded { value in
                            let delta = Int((value.translation.height / Self.rowHeight).rounded())
                            resizeOffset[block.id] = nil
                            planner.resize(blockId: block.id, to: block.length + delta)
                        }
                )
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(tint.opacity(task.isCompleted ? 0.12 : 0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(tint.opacity(isCurrent ? 0.9 : 0.4), lineWidth: isCurrent ? 1.5 : 0.5)
        )
        .overlay {
            if willDiscard {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
        }
        .opacity(willDiscard ? 0.45 : 1)
        .foregroundColor(task.isCompleted ? .secondary : .primary)
        .padding(.leading, Self.labelWidth + 4)
        .offset(x: drag.width, y: y)
        .zIndex(dragOffset[block.id] == nil ? 0 : 1)
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { dragOffset[block.id] = $0.translation }
                .onEnded { value in
                    dragOffset[block.id] = nil
                    // 横に引きずり出したら計画から外す。縦なら 15 分単位で移動
                    if abs(value.translation.width) > Self.discardDistance {
                        withAnimation(.easeOut(duration: 0.15)) { planner.remove(blockId: block.id) }
                        return
                    }
                    let delta = Int((value.translation.height / Self.rowHeight).rounded())
                    planner.move(blockId: block.id, to: block.startSlot + delta)
                }
        )
        .onTapGesture { taskListVM.selectTask(id: task.id) }
        .contextMenu {
            if !task.isCompleted {
                Button(String(localized: "planner.startNow")) { taskListVM.selectTask(id: task.id) }
            }
            Button(String(localized: "planner.remove"), role: .destructive) {
                planner.remove(blockId: block.id)
            }
        }
    }

    /// カレンダーの予定。計画は置けない時間なので斜線で「埋まっている」と見せる
    /// （黒く塗りつぶすとダークモードで背景に沈み、予定名も読めない）
    private func busyView(_ event: BusyBlock, range: Range<Int>) -> some View {
        let start = max(event.startSlot, range.lowerBound)
        let end = min(event.endSlot, range.upperBound)
        return HStack(alignment: .top) {
            Text(event.title)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "calendar")
                .font(.system(size: 8))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .frame(height: CGFloat(end - start) * Self.rowHeight - 2, alignment: .top)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06))
                DiagonalHatch().stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
            }
        )
        .padding(.leading, Self.labelWidth + 4)
        .offset(y: CGFloat(start - range.lowerBound) * Self.rowHeight + 1)
        .allowsHitTesting(false)
        .help(event.title)
    }

    /// 現在時刻の赤線（分単位で位置を出す）
    private func nowLine(range: Range<Int>) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let c = Calendar.current.dateComponents([.hour, .minute], from: context.date)
            let minutes = CGFloat((c.hour ?? 0) * 60 + (c.minute ?? 0))
            let y = (minutes / CGFloat(DayPlan.slotMinutes) - CGFloat(range.lowerBound)) * Self.rowHeight
            HStack(spacing: 0) {
                Circle().fill(Color.red).frame(width: 5, height: 5)
                Rectangle().fill(Color.red.opacity(0.7)).frame(height: 1)
            }
            .padding(.leading, Self.labelWidth - 2)
            .offset(y: y - 2.5)
            .allowsHitTesting(false)
        }
    }

    private func slot(at y: CGFloat, range: Range<Int>) -> Int {
        let index = Int(floor(max(0, y) / Self.rowHeight))
        return min(range.upperBound - 1, range.lowerBound + index)
    }
}

/// 予定で埋まった時間に引く斜線
struct DiagonalHatch: Shape {
    var spacing: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}

// MARK: - Calendar Settings

/// 設定画面の「予定で埋める」部分。Mac のカレンダーはチェックで選び、ics は URL を足していく
/// 値は SettingsView の下書きに書き、保存を押したときに確定する
struct PlannerCalendarSettings: View {
    @Binding var macEnabled: Bool
    @Binding var selectedIds: Set<String>?  // nil = 全カレンダー（あとから増えたカレンダーも含む）
    @Binding var icsURLs: [String]

    @State private var store = EKEventStore()
    @State private var calendars: [EKCalendar] = []
    @State private var accessDenied = false
    @State private var newURL = ""

    var body: some View {
        Section(String(localized: "settings.planner.calendar.section")) {
            Toggle(String(localized: "settings.planner.calendar"), isOn: $macEnabled)
            if macEnabled {
                if accessDenied {
                    Text(String(localized: "settings.planner.calendar.denied"))
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    ForEach(groupedSources, id: \.self) { source in
                        Text(source)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(calendars.filter { $0.source.title == source }, id: \.calendarIdentifier) { calendar in
                            Toggle(isOn: binding(for: calendar.calendarIdentifier)) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color(nsColor: calendar.color ?? .gray))
                                        .frame(width: 8, height: 8)
                                    Text(calendar.title)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }

            ForEach(icsURLs, id: \.self) { url in
                HStack {
                    Image(systemName: "link").font(.caption).foregroundColor(.secondary)
                    Text(url)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        icsURLs.removeAll { $0 == url }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
            HStack {
                TextField(String(localized: "settings.planner.ics.placeholder"), text: $newURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit(addURL)
                Button(String(localized: "settings.planner.ics.add"), action: addURL)
                    .disabled(!isValidURL(newURL))
            }

            Text(String(localized: "settings.planner.calendar.help"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await loadCalendars() }
        .onChange(of: macEnabled) { _, enabled in
            if enabled { Task { await loadCalendars() } }
        }
    }

    private var groupedSources: [String] {
        Array(Set(calendars.map { $0.source.title })).sorted()
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedIds?.contains(id) ?? true },
            set: { on in
                var ids = selectedIds ?? Set(calendars.map(\.calendarIdentifier))
                if on { ids.insert(id) } else { ids.remove(id) }
                // 全部に戻ったら「全カレンダー」として持つ（あとで足したカレンダーも自動で入る）
                selectedIds = ids == Set(calendars.map(\.calendarIdentifier)) ? nil : ids
            })
    }

    /// 許可済みならカレンダー一覧を出す。オンにした直後で未確認なら、ここで許可を求める
    private func loadCalendars() async {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            break
        case .notDetermined where macEnabled:
            guard (try? await store.requestFullAccessToEvents()) == true else {
                accessDenied = true
                return
            }
        case .notDetermined:
            return
        default:
            accessDenied = true
            return
        }
        accessDenied = false
        calendars = store.calendars(for: .event).sorted { $0.title < $1.title }
    }

    private func isValidURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "webcal"].contains(scheme) && url.host != nil && !icsURLs.contains(trimmed)
    }

    private func addURL() {
        guard isValidURL(newURL) else { return }
        icsURLs.append(newURL.trimmingCharacters(in: .whitespaces))
        newURL = ""
    }
}
