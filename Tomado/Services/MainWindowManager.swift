import AppKit
import SwiftUI

@MainActor
class MainWindowManager: ObservableObject {
    static let shared = MainWindowManager()

    // ウィンドウデリゲートを強参照で保持（複数ウィンドウ対応）
    private var windowDelegates: [ObjectIdentifier: MainWindowDelegate] = [:]

    private init() {
        loadWindowSettings()
    }

    private func loadWindowSettings() {
        // 設定読み込み処理は後で実装
    }

    func configureWindow(_ window: NSWindow) {
        // 保存された設定があれば適用（画面外チェック付き）
        if let savedFrame = getSavedWindowFrame() {
            let validatedFrame = validateWindowFrame(savedFrame)
            window.setFrame(validatedFrame, display: true)
        }
    }

    func getInitialWindowFrame() -> NSRect {
        if let savedFrame = getSavedWindowFrame() {
            return validateWindowFrame(savedFrame)
        } else {
            // デフォルトフレーム
            return NSRect(x: 100, y: 100, width: 750, height: 400)
        }
    }

    private func getSavedWindowFrame() -> NSRect? {
        if UserDefaults.standard.object(forKey: "main_window_frame_x") != nil {
            let x = UserDefaults.standard.double(forKey: "main_window_frame_x")
            let y = UserDefaults.standard.double(forKey: "main_window_frame_y")
            let width = UserDefaults.standard.double(forKey: "main_window_frame_width")
            let height = UserDefaults.standard.double(forKey: "main_window_frame_height")
            return NSRect(x: x, y: y, width: width, height: height)
        }
        return nil
    }

    private func validateWindowFrame(_ frame: NSRect) -> NSRect {
        // 利用可能なスクリーンを取得
        let availableScreens = NSScreen.screens
        guard !availableScreens.isEmpty else {
            return frame
        }

        // メインスクリーンを最優先、次にカーソルがあるスクリーンを使用
        let targetScreen = NSScreen.main ?? availableScreens.first!
        let screenFrame = targetScreen.visibleFrame
        var validatedFrame = frame

        // 最小サイズチェック
        let minWidth: CGFloat = 750
        let minHeight: CGFloat = 400

        if validatedFrame.width < minWidth {
            validatedFrame.size.width = minWidth
        }
        if validatedFrame.height < minHeight {
            validatedFrame.size.height = minHeight
        }

        // 画面サイズチェック（対象スクリーンに対して）
        if validatedFrame.width > screenFrame.width {
            validatedFrame.size.width = screenFrame.width - 100
        }
        if validatedFrame.height > screenFrame.height {
            validatedFrame.size.height = screenFrame.height - 100
        }

        // ウィンドウが対象スクリーン内にあるかチェック
        let windowRight = validatedFrame.origin.x + validatedFrame.width
        let windowTop = validatedFrame.origin.y + validatedFrame.height

        // 対象スクリーン内での位置チェック
        let isInTargetScreen =
            validatedFrame.origin.x >= screenFrame.minX && windowRight <= screenFrame.maxX
            && validatedFrame.origin.y >= screenFrame.minY && windowTop <= screenFrame.maxY

        if !isInTargetScreen {
            // 対象スクリーン内にない場合は、対象スクリーンの中央に配置
            validatedFrame.origin.x =
                screenFrame.origin.x + (screenFrame.width - validatedFrame.width) / 2
            validatedFrame.origin.y =
                screenFrame.origin.y + (screenFrame.height - validatedFrame.height) / 2
        }

        return validatedFrame
    }

    func saveWindowFrame(_ frame: NSRect) {
        UserDefaults.standard.set(frame.origin.x, forKey: "main_window_frame_x")
        UserDefaults.standard.set(frame.origin.y, forKey: "main_window_frame_y")
        UserDefaults.standard.set(frame.size.width, forKey: "main_window_frame_width")
        UserDefaults.standard.set(frame.size.height, forKey: "main_window_frame_height")
    }

    func setupWindowDelegate(for window: NSWindow) {
        // ウィンドウデリゲートを作成し、強参照で保持
        let delegate = MainWindowDelegate()
        let windowId = ObjectIdentifier(window)
        windowDelegates[windowId] = delegate
        window.delegate = delegate
    }

    // MARK: - Window Management

    func restoreOrCreateMainWindow(timer: PomodoroTimer? = nil, excludeWindow: NSWindow? = nil)
        -> Bool
    {
        // 既存のメインウィンドウを復元試行
        if restoreExistingMainWindow(excludeWindow: excludeWindow) {
            return true
        }

        createNewMainWindow(timer: timer)
        return true
    }

    func hideMainWindow() {
        // 全てのメインウィンドウを隠す
        for window in NSApp.windows {
            if isValidMainWindow(window) {
                window.orderOut(nil)
            }
        }
    }

    func showMainWindow() {
        // 既存のメインウィンドウを表示
        for window in NSApp.windows {
            if isValidMainWindow(window) {
                window.orderFront(nil)

                if window.canBecomeKey {
                    window.makeKey()
                }
                if window.canBecomeMain {
                    window.makeMain()
                }

                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }

        // メインウィンドウが見つからない場合は新しく作成
        createNewMainWindow()
    }

    private func restoreExistingMainWindow(excludeWindow: NSWindow? = nil) -> Bool {
        for window in NSApp.windows {
            if window == excludeWindow {
                continue
            }

            if isValidMainWindow(window, excludeWindow: excludeWindow) {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }

                window.orderFront(nil)

                if window.canBecomeKey {
                    window.makeKey()
                }

                if window.canBecomeMain {
                    window.makeMain()
                }

                NSApp.activate(ignoringOtherApps: true)
                return true
            }
        }

        return false
    }

    private func createNewMainWindow(timer: PomodoroTimer? = nil) {
        // 保存されたウィンドウフレームを取得
        let initialFrame = getInitialWindowFrame()

        // 新しいメインウィンドウを作成
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )

        window.title = "Tomado"
        window.setFrameAutosaveName("TomadoMainWindow")

        // ViewModelを準備
        let taskListViewModel = TaskListViewModel()

        // タスクが設定されていれば、ポモドーロタイマーに設定
        Task { @MainActor in
            if let timer = timer {
                if let nextTask = taskListViewModel.taskList.nextTask {
                    timer.setCurrentTask(nextTask)
                }
            }
        }

        // メインコンテンツビューを作成
        let contentView = MainContentView(
            pomodoroTimer: timer ?? PomodoroTimer(),
            taskListViewModel: taskListViewModel
        )

        // HostingViewを作成
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        // ビューの初期化を完了させるため少し待つ
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            window.contentView = hostingView

            DispatchQueue.main.async {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func isValidMainWindow(_ window: NSWindow, excludeWindow: NSWindow? = nil) -> Bool {
        // 除外するウィンドウをチェック
        if let excludeWindow = excludeWindow, window == excludeWindow {
            return false
        }

        // ウィンドウが使用可能かどうかの基本チェック
        let isUsable = window.canBecomeKey || window.canBecomeMain
        if !isUsable {
            return false
        }

        // タイトルによる判定
        let validTitles = ["Tomado", "ポモドーロタイマー"]
        let titleMatch = validTitles.contains(window.title)

        // 構造による判定
        let hasContentViewController = window.contentViewController != nil
        let isNotBorderless = !window.styleMask.contains(.borderless)
        let hasProperStyleMask =
            window.styleMask.contains(.titled) && window.styleMask.contains(.closable)
        let structuralMatch = hasContentViewController && isNotBorderless && hasProperStyleMask

        return titleMatch || structuralMatch
    }
}

// NSWindowにアクセスするためのヘルパービュー
struct MainWindowView: NSViewRepresentable {
    let windowManager = MainWindowManager.shared

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // ビューが表示された後にウィンドウにアクセス
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }

            // ウィンドウが既に設定済みかチェック
            if window.delegate == nil {
                self.windowManager.configureWindow(window)

                // ウィンドウデリゲートを設定してクローズを防ぐ
                self.windowManager.setupWindowDelegate(for: window)

                // ウィンドウの変更を監視
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        self.windowManager.saveWindowFrame(window.frame)
                    }
                }

                NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        self.windowManager.saveWindowFrame(window.frame)
                    }
                }
            }
        }
    }
}

// メインウィンドウのデリゲート
class MainWindowDelegate: NSObject, NSWindowDelegate {

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // ウィンドウを閉じる代わりに最小化
        sender.miniaturize(nil)

        // 実際には閉じない
        return false
    }
}
