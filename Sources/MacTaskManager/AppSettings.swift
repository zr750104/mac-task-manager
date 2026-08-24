import SwiftUI
import AppKit

/// メニューバーに出す項目。
enum MenuBarMetric: String, CaseIterable, Identifiable, Codable {
    case cpu, memory, gpu, neuralEngine, temperature

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "メモリ"
        case .gpu: return "GPU"
        case .neuralEngine: return "Neural Engine"
        case .temperature: return "温度"
        }
    }

    /// メニューバーに数値と並べて出す短いラベル。どの数値が何かを見分けるためのもの。
    var shortLabel: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "MEM"
        case .gpu: return "GPU"
        case .neuralEngine: return "NPU"
        case .temperature: return "TMP"
        }
    }
}

/// ウインドウやメニューバーの表示設定。UserDefaults に保存する。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// 表示中の画面。書き出し機能から切り替えられるようにここで持つ。
    @Published var selection: Panel = .overview

    /// 計測の更新間隔。
    /// MetricsEngine 側に置くと、毎秒の計測更新でメニューが作り直されてしまうため、
    /// 変化の少ない設定側で持つ。
    @Published var refreshRate: RefreshRate {
        didSet {
            defaults.set(refreshRate.rawValue, forKey: Keys.refreshRate)
            MetricsEngine.shared.refreshRateDidChange()
        }
    }

    @Published var isAlwaysOnTop: Bool {
        didSet {
            defaults.set(isAlwaysOnTop, forKey: Keys.alwaysOnTop)
            applyWindowLevel()
        }
    }

    @Published var showsMenuBarItem: Bool {
        didSet { defaults.set(showsMenuBarItem, forKey: Keys.menuBarItem) }
    }

    @Published var menuBarMetrics: Set<MenuBarMetric> {
        didSet {
            defaults.set(menuBarMetrics.map(\.rawValue), forKey: Keys.menuBarMetrics)
        }
    }

    private enum Keys {
        static let alwaysOnTop = "isAlwaysOnTop"
        static let menuBarItem = "showsMenuBarItem"
        static let menuBarMetrics = "menuBarMetrics"
        static let refreshRate = "refreshRate"
    }

    private let defaults = UserDefaults.standard

    private init() {
        // 初回起動時はメニューバー表示を有効、内容は CPU と温度。
        defaults.register(defaults: [
            Keys.menuBarItem: true,
            Keys.alwaysOnTop: false
        ])
        let storedRate = defaults.double(forKey: Keys.refreshRate)
        refreshRate = RefreshRate(rawValue: storedRate) ?? .normal
        isAlwaysOnTop = defaults.bool(forKey: Keys.alwaysOnTop)
        showsMenuBarItem = defaults.bool(forKey: Keys.menuBarItem)
        if let stored = defaults.stringArray(forKey: Keys.menuBarMetrics) {
            menuBarMetrics = Set(stored.compactMap(MenuBarMetric.init(rawValue:)))
        } else {
            menuBarMetrics = [.cpu, .temperature]
        }
    }

    /// 開いているウインドウすべてに最前面設定を反映する。
    func applyWindowLevel() {
        let level: NSWindow.Level = isAlwaysOnTop ? .floating : .normal
        for window in NSApp.windows where window.canBecomeMain {
            window.level = level
        }
    }

    func toggle(_ metric: MenuBarMetric) {
        if menuBarMetrics.contains(metric) {
            // 全部消えると何も出なくなるので、最後の 1 つは残す。
            if menuBarMetrics.count > 1 { menuBarMetrics.remove(metric) }
        } else {
            menuBarMetrics.insert(metric)
        }
    }
}
