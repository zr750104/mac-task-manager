import AppKit

/// メニューバーに出す文字列を、数値が変わっても幅が変わらないように組み立てる。
///
/// 普通に文字列を並べると「9%」→「100%」、「↓512」→「↓1.4M」のように
/// 桁数が変わるたびに後ろの項目が左右に動き、全体の幅も伸び縮みする。
/// そこで項目ごとに「最も幅を取る値」で枠を確保し、タブ位置で固定する。
/// 値は枠の右端にそろえるので、桁が増減しても位置が揺れない。
enum MenuBarTitle {

    struct Item {
        /// 「CPU」などの短いラベル。空ならラベルなし。
        var label: String
        /// 実際に表示する値
        var value: String
        /// この項目が取りうる最大幅の見本（例: "000%"）。幅の確保にだけ使う。
        var widestSample: String
    }

    /// ラベルは数値と同じ文字色にする。
    /// 淡いグレー（secondaryLabelColor）はメニューバーの半透明な背景に溶けて読めなかったため、
    /// 色ではなく「小さめの太字」で数値と区別する。
    static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9, weight: .bold),
        .foregroundColor: NSColor.labelColor
    ]

    /// 数字の幅がそろう等幅数字フォントを使う。
    static let valueAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.labelColor
    ]

    /// 項目同士の間隔
    static let gap: CGFloat = 9

    static func make(_ items: [Item]) -> NSAttributedString {
        let title = NSMutableAttributedString()
        var stops: [NSTextTab] = []
        let space = width(" ", labelAttributes)
        var x: CGFloat = 0

        for item in items {
            let labelWidth = item.label.isEmpty ? 0 : width(item.label, labelAttributes) + space
            let valueWidth = width(item.widestSample, valueAttributes)

            // ラベルの書き出し位置（先頭の項目は 0 から始まるのでタブ不要）
            if !item.label.isEmpty {
                if title.length > 0 {
                    title.append(NSAttributedString(string: "\t", attributes: valueAttributes))
                    stops.append(NSTextTab(textAlignment: .left, location: x))
                }
                title.append(NSAttributedString(string: item.label, attributes: labelAttributes))
            }

            // 値は枠の右端にそろえる
            let end = x + labelWidth + valueWidth
            title.append(NSAttributedString(string: "\t", attributes: valueAttributes))
            stops.append(NSTextTab(textAlignment: .right, location: end))
            title.append(NSAttributedString(string: item.value, attributes: valueAttributes))

            x = end + gap
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = stops
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byClipping
        title.addAttribute(.paragraphStyle, value: paragraph,
                           range: NSRange(location: 0, length: title.length))
        return title
    }

    private static func width(_ text: String, _ attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        ceil((text as NSString).size(withAttributes: attributes).width)
    }
}
