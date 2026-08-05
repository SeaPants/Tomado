import AppKit
import SwiftUI

@main
public struct TomadoApp: App {
    @NSApplicationDelegateAdaptor(TomadoAppDelegate.self) var appDelegate

    public init() {}

    public var body: some Scene {
        // 実際のメインウィンドウは AppDelegate で AppKit 直接生成して
        // SwiftUI WindowGroup の不確実な lifecycle 管理から逃れる。
        // Settings scene はアプリメニューに ⌘, を生やすので、中身も本物の設定にしておく
        // （空にすると ⌘, が白紙のウィンドウを開いてしまう）
        Settings {
            SettingsView(timer: appDelegate.pomodoroTimer)
        }
    }
}

/// メインウィンドウとミニマル状態を AppKit で直接管理する AppDelegate (single source of truth)
@MainActor
final class TomadoAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    static private(set) weak var shared: TomadoAppDelegate?

    let pomodoroTimer = PomodoroTimer()
    let taskListViewModel = TaskListViewModel()

    private(set) var mainWindow: NSWindow?
    private let minimalController = MinimalWindowController()

    /// ミニマルモードの真の状態。view は読み取り、変更は toggleMinimalMode() を通す
    @Published private(set) var isMinimalMode: Bool = false

    override init() {
        super.init()
        TomadoAppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyPresetDurationsOnFirstLaunch()

        // 初回タスク選択
        if let nextTask = taskListViewModel.taskList.nextTask {
            pomodoroTimer.setCurrentTask(nextTask)
        }
        // 起動時は必ず標準モード開始（前回ミニマルだったら復元はせず、安全側に倒す）
        isMinimalMode = false
        showMainWindow()
    }

    /// 初回起動時、タイマーの時間をフッターに出ているプリセット（既定は 🐇 Short Focus）に合わせる。
    /// 揃えないと 🐇 表示なのに 25:00 という食い違いが出る
    private func applyPresetDurationsOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "pomodoro_work_duration") == nil else { return }

        let preset = defaults.string(forKey: "timerPreset") ?? "shortFocus"
        func minutes(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: key) as? Int ?? fallback
        }
        let (work, breakMin, longBreak) = preset == "deepFocus"
            ? (minutes("deepFocusWork", 35), minutes("deepFocusBreak", 10), minutes("deepFocusLongBreak", 30))
            : (minutes("shortFocusWork", 12), minutes("shortFocusBreak", 3), minutes("shortFocusLongBreak", 15))

        pomodoroTimer.updateSettings(
            workMinutes: work,
            breakMinutes: breakMin,
            longBreakMinutes: longBreak,
            pomodorosUntilLongBreak: pomodoroTimer.pomodorosUntilLongBreak
        )
    }

    /// ミニマルモードを切替
    func toggleMinimalMode() {
        setMinimalMode(!isMinimalMode)
    }

    /// ミニマルモードを明示設定
    func setMinimalMode(_ minimal: Bool) {
        guard isMinimalMode != minimal else { return }
        isMinimalMode = minimal
        applyMinimalMode()
    }

    private func applyMinimalMode() {
        if isMinimalMode {
            minimalController.show(
                timer: pomodoroTimer,
                taskListVM: taskListViewModel,
                onExit: { [weak self] in
                    self?.setMinimalMode(false)
                }
            )
            hideMainWindow()
        } else {
            minimalController.hide()
            showMainWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        // ミニマル時は親を隠すため最後のウィンドウが消えるが終了しない
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    /// メインウィンドウを表示（無ければ生成）
    func showMainWindow() {
        if let win = mainWindow {
            win.alphaValue = 1
            win.ignoresMouseEvents = false
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // 規定サイズ
        let defaultSize = NSSize(width: 360, height: 560)
        let minSize = NSSize(width: 320, height: 440)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let initialFrame = NSRect(
            x: screen.midX - defaultSize.width / 2,
            y: screen.midY - defaultSize.height / 2,
            width: defaultSize.width,
            height: defaultSize.height
        )

        // .fullSizeContentView は外す（minSize 計算が複雑化するのを避ける）
        let win = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Tomado"
        win.isReleasedWhenClosed = false

        let view = MainContentView(
            pomodoroTimer: pomodoroTimer,
            taskListViewModel: taskListViewModel
        )
        let host = NSHostingView(rootView: view)
        win.contentView = host

        // contentView をセットした後で minSize を設定（順序が重要）
        win.contentMinSize = minSize
        // frame minSize はタイトルバー込み
        let titleBarHeight = win.frame.height - (win.contentLayoutRect.height)
        win.minSize = NSSize(width: minSize.width, height: minSize.height + titleBarHeight)

        // close ボタンで終了させない
        MainWindowManager.shared.setupWindowDelegate(for: win)

        // autosave で復元
        win.setFrameAutosaveName("TomadoMain.v2")
        // 最小サイズを下回る復元結果（旧版の遺物など）だけ初期 frame に戻す。
        // 上限は設けない — ユーザーが広げたウィンドウを毎回畳んでしまうため
        if win.frame.width < minSize.width || win.frame.height < minSize.height {
            win.setFrame(initialFrame, display: false)
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.mainWindow = win
    }

    /// メインウィンドウを完全に隠す（手動 NSWindow なので orderOut で確実に消える）
    func hideMainWindow() {
        guard let win = mainWindow else { return }
        win.orderOut(nil)
    }
}
