import SwiftUI
import AppKit

@main
struct MacTaskManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // メニューバー常駐からも同じ計測結果を使うため、生成箇所を一本化している。
    //
    // engine と updates は @StateObject にしない。
    // App が監視すると、毎秒の計測更新のたびに body が再評価され、
    // .commands（メニュー）ごと作り直されてしまうため。
    // 画面側は @EnvironmentObject で受け取って各自が監視する。
    private let engine = MetricsEngine.shared
    private let updates = UpdateChecker.shared
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup("タスクマネージャー") {
            ContentView()
                .environmentObject(engine)
                .environmentObject(settings)
                .environmentObject(updates)
                // 小さく畳んで常時表示できるように、最小サイズは低めにしてある。
                // 各画面のタイルは幅に応じて折り返す。
                .frame(minWidth: 480, minHeight: 320)
                .background(WindowLevelApplier())
        }
        .defaultSize(width: 1160, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("アップデートを確認…") {
                    Task { await updates.check(userInitiated: true) }
                }
            }
            // 標準の「表示」メニューと名前が衝突しないようにする。
            CommandMenu("モニター") {
                Picker("更新間隔", selection: $settings.refreshRate) {
                    ForEach(RefreshRate.allCases) { rate in
                        Text(rate.label).tag(rate)
                    }
                }
                Divider()
                Toggle("常に最前面に表示", isOn: $settings.isAlwaysOnTop)
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Toggle("メニューバーに表示", isOn: $settings.showsMenuBarItem)
                Divider()
                Picker("ウィジェットの更新間隔", selection: $settings.widgetRefreshInterval) {
                    ForEach(WidgetRefreshInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
            }
        }
    }
}

/// SwiftUI のウインドウに「常に最前面」設定を反映させるための橋渡し。
private struct WindowLevelApplier: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // ウインドウに載ったあとでないと window が nil なので次のループで適用する。
        DispatchQueue.main.async {
            AppSettings.shared.applyWindowLevel()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        AppSettings.shared.applyWindowLevel()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .app バンドル外から直接起動された場合でも通常のウインドウ付きアプリとして振る舞わせる。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        menuBar = MenuBarController(engine: .shared, settings: .shared)

        // 紹介資料用の画面書き出しモード。
        if let directory = ScreenshotExporter.requestedDirectory {
            ScreenshotExporter.run(directory: directory, engine: .shared, settings: .shared)
            return
        }
        StandardMenu.install()
        WidgetRefresher.start(interval: AppSettings.shared.widgetRefreshInterval)
        UpdateChecker.shared.checkOnLaunchIfNeeded()
    }

    /// メニューバーに常駐している間はウインドウを閉じても終了しない。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppSettings.shared.showsMenuBarItem
    }
}
