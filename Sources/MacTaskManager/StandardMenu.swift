import AppKit

/// macOS 標準の「ウインドウ」「表示」メニューを組み立てる。
///
/// SwiftUI の `WindowGroup` が用意するウインドウメニューは
/// 「しまう / 拡大・縮小 / すべてを手前に移動」だけで、
/// AppKit 製アプリ（Xcode の MainMenu.xib を使うもの）にある
/// フルスクリーン・タブ操作・整列などが入らない。
/// そこで起動後に AppKit 側で組み直している。
@MainActor
final class StandardMenu: NSObject, NSMenuDelegate {

    static let shared = StandardMenu()
    private static var observer: NSObjectProtocol?

    /// SwiftUI などが元々設定していた delegate。動作を奪わないよう引き継ぐ。
    private weak var previousDelegate: NSMenuDelegate?

    /// メニューバーが開かれる直前に呼ばれる。
    /// SwiftUI に作り直されていたら、ここで当て直す。
    func menuNeedsUpdate(_ menu: NSMenu) {
        previousDelegate?.menuNeedsUpdate?(menu)
        StandardMenu.reapplyIfNeeded()
    }

    func menuWillOpen(_ menu: NSMenu) {
        previousDelegate?.menuWillOpen?(menu)
        StandardMenu.reapplyIfNeeded()
    }

    /// SwiftUI がメニューを作り終えてから適用する。
    /// SwiftUI は状態が変わるとメニューを組み直すことがあるため、
    /// アプリがアクティブになるたびに作り直しを検知して当て直す。
    static func install() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            apply()
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { _ in
                Task { @MainActor in reapplyIfNeeded() }
            }
        // メニューバー本体の delegate になっておくと、
        // どのメニューを開くときでも直前に点検できる。
        if let main = NSApp.mainMenu, main.delegate !== shared {
            shared.previousDelegate = main.delegate
            main.delegate = shared
        }
    }

    /// SwiftUI に作り直されて標準項目が消えていたら当て直す。
    static func reapplyIfNeeded() {
        guard let main = NSApp.mainMenu,
              let windowItem = main.items.first(where: {
                  $0.title == "ウインドウ" || $0.title == "Window"
              }), let menu = windowItem.submenu else { return }
        let fullScreen = NSSelectorFromString("toggleFullScreen:")
        if !menu.items.contains(where: { $0.action == fullScreen }) {
            apply()
        }
    }

    static func apply() {
        guard let main = NSApp.mainMenu else { return }
        fixViewMenu(in: main)
        rebuildWindowMenu(in: main)
    }

    // MARK: - 表示メニュー

    /// SwiftUI はサイドバーの項目をヘルプメニューに入れてしまうことがあるため、
    /// 「表示」へ移してから整える。
    private static func fixViewMenu(in main: NSMenu) {
        let toggleSidebar = NSSelectorFromString("toggleSidebar:")

        // ヘルプに紛れ込んだサイドバー項目を取り除く。
        for item in main.items {
            guard item.title.contains("ヘルプ") || item.title == "Help",
                  let help = item.submenu else { continue }
            for sub in help.items where sub.action == toggleSidebar {
                help.removeItem(sub)
            }
        }

        guard let viewItem = main.items.first(where: { $0.title == "表示" || $0.title == "View" })
        else { return }
        let view = viewItem.submenu ?? {
            let menu = NSMenu(title: viewItem.title)
            viewItem.submenu = menu
            return menu
        }()

        guard !view.items.contains(where: { $0.action == toggleSidebar }) else { return }
        let sidebar = NSMenuItem(title: "サイドバーを表示/非表示",
                                 action: toggleSidebar, keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        view.insertItem(sidebar, at: 0)
    }

    // MARK: - ウインドウメニュー

    private static func rebuildWindowMenu(in main: NSMenu) {
        guard let windowItem = main.items.first(where: {
            $0.title == "ウインドウ" || $0.title == "Window"
        }), let menu = windowItem.submenu else { return }

        // 中身は作り直す。ウインドウ一覧は最後に AppKit が足してくれる。
        menu.removeAllItems()

        add(menu, "しまう", "performMiniaturize:", key: "m", modifiers: [.command])
        addAlternate(menu, "すべてをしまう", "miniaturizeAll:", key: "m")
        add(menu, "拡大/縮小", "performZoom:")
        addAlternate(menu, "すべてを拡大/縮小", "zoomAll:", key: "")

        // Fill / Center は macOS のウインドウ整列。非公開のため存在を確かめてから足す。
        var addedTiling = false
        if NSWindow.instancesRespond(to: NSSelectorFromString("_zoomFill:")) {
            add(menu, "画面いっぱいに配置", "_zoomFill:", key: "f", modifiers: [.control, .option])
            addedTiling = true
        }
        if NSWindow.instancesRespond(to: NSSelectorFromString("_zoomCenter:")) {
            add(menu, "中央に配置", "_zoomCenter:", key: "c", modifiers: [.control, .option])
            addedTiling = true
        }
        if addedTiling { menu.addItem(.separator()) }

        add(menu, "フルスクリーンにする", "toggleFullScreen:", key: "f", modifiers: [.control, .command])
        menu.addItem(.separator())

        add(menu, "タブバーを表示/非表示", "toggleTabBar:")
        add(menu, "次のタブを表示", "selectNextTab:")
        add(menu, "前のタブを表示", "selectPreviousTab:")
        add(menu, "タブを新規ウインドウに移動", "moveTabToNewWindow:")
        add(menu, "すべてのウインドウを結合", "mergeAllWindows:")
        menu.addItem(.separator())

        add(menu, "すべてを手前に移動", "arrangeInFront:")

        // ウインドウメニュー自体には delegate を付けない。
        // AppKit がウインドウ一覧を管理しているため、横取りすると壊れる。
        // AppKit にウインドウ一覧の追加を任せる。
        NSApp.windowsMenu = menu
    }

    // MARK: - 部品

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ selector: String,
                            key: String = "",
                            modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        // target を nil にするとレスポンダチェーンへ流れ、
        // 対象のウインドウが無いときは自動的に無効表示になる。
        item.target = nil
        menu.addItem(item)
        return item
    }

    /// Option キーを押している間だけ現れる項目。直前の項目と同じキーを共有する。
    private static func addAlternate(_ menu: NSMenu, _ title: String, _ selector: String, key: String) {
        let item = add(menu, title, selector, key: key, modifiers: [.command, .option])
        item.isAlternate = true
        item.keyEquivalentModifierMask = [.command, .option]
    }
}
