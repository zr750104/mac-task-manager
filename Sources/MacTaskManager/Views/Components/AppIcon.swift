import SwiftUI
import AppKit

/// アプリのアイコンを表示する。
///
/// `NSWorkspace.icon(forFile:)` はディスクを読むため、
/// 毎回の再描画で呼ぶと無駄が大きい。パスごとに一度だけ読んで使い回す。
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage?] = [:]

    static func icon(atPath path: String?) -> NSImage? {
        guard let path else { return nil }
        if let cached = cache[path] { return cached }

        var image: NSImage?
        if FileManager.default.fileExists(atPath: path) {
            let loaded = NSWorkspace.shared.icon(forFile: path)
            loaded.size = NSSize(width: 32, height: 32)
            image = loaded
        }
        // 見つからなかったことも覚えておき、毎回探しに行かないようにする。
        cache[path] = image
        return image
    }
}

/// アプリのアイコン。読み込めないときは記号で代用する。
struct AppIconView: View {
    var bundlePath: String?
    var isApp: Bool
    var size: CGFloat = 18

    var body: some View {
        if let icon = AppIconCache.icon(atPath: bundlePath) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: isApp ? "app.fill" : "gearshape.fill")
                .font(.system(size: size * 0.7))
                .foregroundStyle(isApp ? Palette.memory : .secondary)
                .frame(width: size, height: size)
        }
    }
}
