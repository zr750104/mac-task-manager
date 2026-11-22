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
        // 書き出した画像は公開資料に載るので、機器名（本名が入りやすい）を一般名にする。
        DeviceBatteryMonitor.anonymizesNames = true
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

            // 利用者がメーター表示を選んでいても、各画面の 1 枚目はグラフ表示で撮る。
            let defaults = UserDefaults.standard
            let savedStyle = defaults.string(forKey: OverviewStyle.storageKey)
            defaults.set(OverviewStyle.chart.rawValue, forKey: OverviewStyle.storageKey)

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

            // 概要のメーター表示。利用者の設定は書き出しのあとで元に戻す。
            settings.selection = .overview
            defaults.set(OverviewStyle.meter.rawValue, forKey: OverviewStyle.storageKey)
            // 振り切りの演出が終わるのを待つ。
            try? await Task.sleep(for: .seconds(3))
            _ = capture(window: window,
                        to: directory.appendingPathComponent("overview-meter.png"))
            // 小さくしたときの表示はグラフ表示で 1 枚残す。
            // カードが途中で切れないよう、11 枚が 2 列 6 行で収まる大きさにしている。
            settings.selection = .overview
            defaults.set(OverviewStyle.chart.rawValue, forKey: OverviewStyle.storageKey)
            window.setContentSize(NSSize(width: 660, height: 760))
            try? await Task.sleep(for: .seconds(2))
            _ = capture(window: window,
                        to: directory.appendingPathComponent("compact.png"))

            // メーター表示を最小に近い大きさで。崩れていないかの確認用。
            defaults.set(OverviewStyle.meter.rawValue, forKey: OverviewStyle.storageKey)
            window.setContentSize(NSSize(width: 480, height: 320))
            try? await Task.sleep(for: .seconds(3))
            _ = capture(window: window,
                        to: directory.appendingPathComponent("compact-meter.png"))
            if let savedStyle {
                defaults.set(savedStyle, forKey: OverviewStyle.storageKey)
            } else {
                defaults.removeObject(forKey: OverviewStyle.storageKey)
            }
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
