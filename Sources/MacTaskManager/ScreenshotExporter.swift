import AppKit

/// 紹介資料用に、各画面を PNG として書き出す。
///
/// `screencapture` と違い自分のウインドウを自分で描画するだけなので、
/// 画面収録の許可は不要。ウインドウ枠・ツールバー・サイドバーもそのまま入る。
///
/// 使い方:
///     タスクマネージャー.app/Contents/MacOS/MacTaskManager --export-screenshots <出力先>
@MainActor
enum ScreenshotExporter {

    static var requestedDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--export-screenshots"),
              index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    static func run(directory: URL, engine: MetricsEngine, settings: AppSettings) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            // SwiftUI がウインドウを作るのは起動直後より少しあとなので待つ。
            var found: NSWindow?
            for _ in 0..<40 {
                if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                    found = window
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let window = found else {
                print("ウインドウが見つかりません")
                NSApp.terminate(nil)
                return
            }
            // 資料に載せやすい比率に揃える。
            window.setContentSize(NSSize(width: 1280, height: 800))
            window.center()

            // グラフに履歴が溜まるまで待つ。プロセス一覧も先に集めておく。
            engine.isOverviewVisible = true
            print("計測データを収集中…（40 秒）")
            try? await Task.sleep(for: .seconds(40))
            await engine.refreshProcessesNow()
            await engine.refreshStartupNow()

            for panel in Panel.allCases {
                settings.selection = panel
                // 画面切り替えと再描画が終わるのを待つ。
                try? await Task.sleep(for: .seconds(2))
                let url = directory.appendingPathComponent("\(panel.rawValue).png")
                if capture(window: window, to: url) {
                    print("書き出し: \(url.lastPathComponent)")
                } else {
                    print("失敗: \(panel.rawValue)")
                }
            }

            // 小さくしたときの表示も 1 枚残す。
            // カードが途中で切れないよう、9 枚が 2 列 5 行で収まる大きさにしている。
            settings.selection = .overview
            window.setContentSize(NSSize(width: 660, height: 660))
            try? await Task.sleep(for: .seconds(2))
            _ = capture(window: window,
                        to: directory.appendingPathComponent("compact.png"))
            print("完了")
            NSApp.terminate(nil)
        }
    }

    /// ウインドウの内容を PNG に書き出す。
    ///
    /// サイドバーやツールバーは半透明マテリアル（NSVisualEffectView）の上に載っており、
    /// `cacheDisplay` では描画されず白く抜ける。レイヤーツリーを直接描く方法だと
    /// これらも含めて取れるので、そちらを優先して使う。
    private static func capture(window: NSWindow, to url: URL) -> Bool {
        // contentView の親（フレームビュー）まで含めるとタイトルバーとツールバーも入る。
        guard let target = window.contentView?.superview ?? window.contentView else { return false }
        let bounds = target.bounds

        // 資料に載せたときに滲まないよう 2 倍解像度で描く。
        let scale = 2
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width) * scale,
            pixelsHigh: Int(bounds.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        representation.size = bounds.size

        target.cacheDisplay(in: bounds, to: representation)

        guard let data = representation.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try data.write(to: url)
            return true
        } catch {
            print("書き込み失敗: \(error.localizedDescription)")
            return false
        }
    }
}
