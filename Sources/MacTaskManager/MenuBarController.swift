import AppKit
import SwiftUI
import Combine

/// メニューバーに常駐して主要な値を表示する。
/// ウインドウを開かずに CPU / 温度などを見られるようにするためのもの。
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let engine: MetricsEngine
    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()
    private var lastUpdate = Date.distantPast

    init(engine: MetricsEngine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
        super.init()

        settings.$showsMenuBarItem
            .sink { [weak self] shows in
                Task { @MainActor in shows ? self?.install() : self?.remove() }
            }
            .store(in: &cancellables)

        // 表示内容の変更は即座に反映する。
        settings.$menuBarMetrics
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.lastUpdate = .distantPast
                    self?.refresh()
                }
            }
            .store(in: &cancellables)

        engine.$snapshot
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)
    }

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 幅を最小にするため、アイコンは付けず表示そのものを画像で出す。
        item.button?.imagePosition = .imageOnly
        item.button?.setAccessibilityLabel("タスクマネージャー")
        item.menu = buildMenu()
        statusItem = item
        lastUpdate = .distantPast
        refresh()
    }

    private func remove() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    /// メニューバーの文字を更新する。1 秒より短い間隔では更新しない。
    private func refresh() {
        guard let button = statusItem?.button else { return }
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= 1 else { return }
        lastUpdate = now

        // 上段にラベル・下段に数値の 2 段で並べ、横幅を最小にする。
        // 列の幅は最大値で決めるので、数値の桁が変わっても全体は動かない。
        button.title = ""
        button.image = MenuBarImage.make(columns())
        button.toolTip = tooltip()
        updateMenuValues()
    }

    /// 表示する列を組み立てる。受信・送信が両方あれば上下に重ねて 1 列にする。
    private func columns() -> [MenuBarImage.Column] {
        let enabled = MenuBarMetric.allCases.filter { settings.menuBarMetrics.contains($0) }
        let bothNetwork = enabled.contains(.networkDown) && enabled.contains(.networkUp)
        var result: [MenuBarImage.Column] = []

        for metric in enabled {
            switch metric {
            case .networkDown, .networkUp:
                if bothNetwork {
                    // 2 つ目は 1 つ目の列に含めて描くので飛ばす。
                    guard metric == .networkDown else { continue }
                    result.append(.init(top: value(for: .networkUp),
                                        bottom: value(for: .networkDown),
                                        topSample: widestSample(for: .networkUp),
                                        bottomSample: widestSample(for: .networkDown),
                                        topIsLabel: false))
                } else {
                    result.append(.init(top: "NET", bottom: value(for: metric),
                                        topSample: "NET", bottomSample: widestSample(for: metric),
                                        topIsLabel: true))
                }
            default:
                result.append(.init(top: metric.shortLabel, bottom: value(for: metric),
                                    topSample: metric.shortLabel,
                                    bottomSample: widestSample(for: metric),
                                    topIsLabel: true))
            }
        }
        return result
    }

    /// 2 段表示は小さいので、カーソルを乗せたときに文字で全体を読めるようにする。
    private func tooltip() -> String {
        MenuBarMetric.allCases
            .filter { settings.menuBarMetrics.contains($0) }
            .map { "\($0.label) \(value(for: $0))" }
            .joined(separator: "  ")
    }

    /// その項目が取りうる最大の幅。これで枠の大きさを決める。
    /// 等幅数字なので数字は "0" で代表させ、単位は最も幅の広いものを入れておく。
    private func widestSample(for metric: MenuBarMetric) -> String {
        switch metric {
        case .cpu, .memory, .gpu, .neuralEngine: return "000%"
        case .networkDown: return "↓000M"
        case .networkUp: return "↑000M"
        case .temperature: return "000℃"
        }
    }

    private func value(for metric: MenuBarMetric) -> String {
        let snapshot = engine.snapshot
        switch metric {
        case .cpu:
            return Fmt.percent(snapshot.cpu.total, decimals: 0)
        case .memory:
            return Fmt.percent(snapshot.memory.usedRatio, decimals: 0)
        case .gpu:
            return snapshot.gpu.available
                ? Fmt.percent(snapshot.gpu.utilization, decimals: 0) : "—"
        case .neuralEngine:
            return snapshot.neuralEngine.available
                ? Fmt.percent(snapshot.neuralEngine.utilization, decimals: 0) : "—"
        // 矢印を数値と同じ大きさで出すため、値の側に含める。
        case .networkDown:
            return "↓" + Fmt.compactRate(snapshot.network.downloadRate)
        case .networkUp:
            return "↑" + Fmt.compactRate(snapshot.network.uploadRate)
        case .temperature:
            return engine.temperature.available
                ? String(format: "%.0f℃", engine.temperature.socMax) : "—"
        }
    }

    // MARK: - メニュー

    private var valueItems: [MenuBarMetric: NSMenuItem] = [:]
    private var alwaysOnTopItem: NSMenuItem?
    private var metricItems: [MenuBarMetric: NSMenuItem] = [:]

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        valueItems.removeAll()
        metricItems.removeAll()

        for metric in MenuBarMetric.allCases {
            let item = NSMenuItem(title: metric.label, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            valueItems[metric] = item
        }

        menu.addItem(.separator())

        let open = NSMenuItem(title: "ウインドウを表示",
                              action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let onTop = NSMenuItem(title: "常に最前面に表示",
                               action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        onTop.target = self
        onTop.state = settings.isAlwaysOnTop ? .on : .off
        menu.addItem(onTop)
        alwaysOnTopItem = onTop

        let display = NSMenuItem(title: "メニューバーに表示する項目", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for metric in MenuBarMetric.allCases {
            let item = NSMenuItem(title: metric.label,
                                  action: #selector(toggleMetric(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = metric.rawValue
            item.state = settings.menuBarMetrics.contains(metric) ? .on : .off
            submenu.addItem(item)
            metricItems[metric] = item
        }
        display.submenu = submenu
        menu.addItem(display)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "タスクマネージャーを終了",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    /// メニューを開いたときに見える数値を最新にする。
    private func updateMenuValues() {
        let snapshot = engine.snapshot
        valueItems[.cpu]?.title = "CPU  \(Fmt.percent(snapshot.cpu.total))"
        valueItems[.memory]?.title =
            "メモリ  \(Fmt.percent(snapshot.memory.usedRatio))  (\(Fmt.bytes(snapshot.memory.used)))"
        valueItems[.gpu]?.title = snapshot.gpu.available
            ? "GPU  \(Fmt.percent(snapshot.gpu.utilization))" : "GPU  —"
        valueItems[.neuralEngine]?.title = snapshot.neuralEngine.available
            ? String(format: "Neural Engine  %@（%.2f W・%@）",
                     Fmt.percent(snapshot.neuralEngine.utilization),
                     snapshot.neuralEngine.watts, snapshot.neuralEngine.stateLabel)
            : "Neural Engine  —"
        valueItems[.networkDown]?.title =
            "ネットワーク 受信  \(Fmt.rate(snapshot.network.downloadRate))"
        valueItems[.networkUp]?.title =
            "ネットワーク 送信  \(Fmt.rate(snapshot.network.uploadRate))"
        valueItems[.temperature]?.title = engine.temperature.available
            ? String(format: "温度  %.1f ℃", engine.temperature.socMax) : "温度  —"
        alwaysOnTopItem?.state = settings.isAlwaysOnTop ? .on : .off
        for (metric, item) in metricItems {
            item.state = settings.menuBarMetrics.contains(metric) ? .on : .off
        }
    }

    // MARK: - 操作

    @objc private func openWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // 閉じている場合は SwiftUI が用意した復元用メニュー項目を使って開き直す。
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
        }
        settings.applyWindowLevel()
    }

    @objc private func toggleAlwaysOnTop() {
        settings.isAlwaysOnTop.toggle()
        alwaysOnTopItem?.state = settings.isAlwaysOnTop ? .on : .off
    }

    @objc private func toggleMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let metric = MenuBarMetric(rawValue: raw) else { return }
        settings.toggle(metric)
        sender.state = settings.menuBarMetrics.contains(metric) ? .on : .off
    }
}
