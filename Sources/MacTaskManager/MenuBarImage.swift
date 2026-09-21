import AppKit

/// メニューバーに出す表示を画像として描く。
///
/// ラベルと数値を横に並べると、どう詰めても幅を取る。
/// そこで 1 項目を「上段にラベル・下段に数値」の縦 2 段にして、横幅を数値 1 つぶんに抑える。
/// 受信・送信は上下に重ねて 1 列にまとめる。
///
/// 各列の幅は「最も幅を取る値」で先に決めるので、数値の桁が変わっても全体は動かない。
/// テンプレート画像にしてあるため、ダーク／ライトや選択時の色はシステムが合わせてくれる
/// （淡いグレーのように背景に溶けることもない）。
enum MenuBarImage {

    struct Column {
        var top: String
        var bottom: String
        /// 上段・下段それぞれが取りうる最大幅の見本
        var topSample: String
        var bottomSample: String
        /// 上段がラベルか（false なら上段も数値として描く。ネットワーク用）
        var topIsLabel: Bool
    }

    static let labelFont = NSFont.systemFont(ofSize: 8, weight: .bold)
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    /// 2 段とも数値のとき（ネットワーク）はやや小さくして収める
    static let compactValueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)

    /// 列と列のすき間
    static let gap: CGFloat = 5

    static func make(_ columns: [Column]) -> NSImage {
        let height = max(22, NSStatusBar.system.thickness)
        let layout = columns.map { column -> (column: Column, width: CGFloat) in
            let topFont = column.topIsLabel ? labelFont : compactValueFont
            let bottomFont = column.topIsLabel ? valueFont : compactValueFont
            let width = max(textWidth(column.top, topFont),
                            textWidth(column.topSample, topFont),
                            textWidth(column.bottomSample, bottomFont))
            return (column, width)
        }
        let totalWidth = layout.map(\.width).reduce(0, +)
            + gap * CGFloat(max(0, layout.count - 1)) + 2

        let image = NSImage(size: NSSize(width: ceil(totalWidth), height: height),
                            flipped: true) { _ in
            var x: CGFloat = 1
            for (column, width) in layout {
                let topFont = column.topIsLabel ? labelFont : compactValueFont
                let bottomFont = column.topIsLabel ? valueFont : compactValueFont
                let topHeight = lineHeight(topFont)
                let bottomHeight = lineHeight(bottomFont)
                // 2 段ぶんの高さを縦中央に置く
                let top = (height - topHeight - bottomHeight) / 2
                draw(column.top, font: topFont, rightEdge: x + width, y: top)
                draw(column.bottom, font: bottomFont, rightEdge: x + width, y: top + topHeight)
                x += width + gap
            }
            return true
        }
        // 黒で描いておけば、システムが背景に合わせて白黒を反転してくれる。
        image.isTemplate = true
        return image
    }

    /// 右端をそろえて描く。桁が減っても右端の位置は変わらない。
    private static func draw(_ text: String, font: NSFont, rightEdge: CGFloat, y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font,
                                                         .foregroundColor: NSColor.black]
        let width = textWidth(text, font)
        (text as NSString).draw(at: NSPoint(x: rightEdge - width, y: y), withAttributes: attributes)
    }

    private static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender)
    }
}
