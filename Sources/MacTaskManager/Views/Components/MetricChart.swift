import SwiftUI
import AppKit
import QuartzCore

/// 時系列を塗りつぶし付きの曲線で描くグラフ。左が過去・右が現在。
///
/// 新しい値が入るたびに、線全体が 1 目盛りぶん右から左へ滑らかに流れ、
/// 先端の光点が新しい高さへ移りながら波紋を広げる。
///
/// アニメーションは SwiftUI ではなく Core Animation で動かしている。
/// 実測すると、この画面では SwiftUI のアニメーションを 1 つ動かすだけで
/// 毎フレーム画面全体が再計算され、負荷が 7.6% → 26〜45% に跳ね上がった。
/// Core Animation なら各フレームは OS の描画プロセスが処理するので、
/// アプリは値が来たときに 1 回指示を出すだけで済む。
struct MetricChart: NSViewRepresentable {
    var values: [Double]
    /// 縦軸の上限。nil なら実データから自動でスケールする。
    var maxValue: Double?
    var color: Color
    var showsGrid: Bool = true
    var gridRows: Int = 4
    var gridColumns: Int = 6
    var lineWidth: CGFloat = 1.5
    /// 線の発光と先端の光点。小さなグラフでは切る。
    var decorated: Bool = true
    /// 値が入ったときに流れる動きを付けるか。小さく数が多いグラフでは切る。
    var animated: Bool = true

    func makeNSView(context: Context) -> ChartLayerView { ChartLayerView() }

    func updateNSView(_ view: ChartLayerView, context: Context) {
        view.update(values: values,
                    ceiling: ChartScale.ceiling(maxValue: maxValue, values: values),
                    color: NSColor(color),
                    showsGrid: showsGrid, gridRows: gridRows, gridColumns: gridColumns,
                    lineWidth: lineWidth, decorated: decorated,
                    animated: animated && !context.environment.accessibilityReduceMotion)
    }
}

/// 縦軸の上限の決め方。
enum ChartScale {
    static func ceiling(maxValue: Double?, values: [Double]) -> Double {
        if let maxValue { return maxValue }
        let peak = values.max() ?? 0
        guard peak > 0 else { return 1 }
        // 自動スケールは「切りのいい値」に丸めて目盛りの跳ねを抑える。
        let magnitude = pow(10, floor(log10(peak)))
        let normalized = peak / magnitude
        let step: Double = normalized <= 1 ? 1 : (normalized <= 2 ? 2 : (normalized <= 5 ? 5 : 10))
        return step * magnitude
    }
}

/// グラフ本体。レイヤーを組み立てておき、値が来たら形を差し替えて動きを付ける。
final class ChartLayerView: NSView {
    private let grid = CAShapeLayer()
    /// 線と塗りをまとめて横に滑らせるための入れ物
    private let content = CALayer()
    private let fill = CAGradientLayer()
    private let fillMask = CAShapeLayer()
    private let glow = CAShapeLayer()
    private let stroke = CAGradientLayer()
    private let strokeMask = CAShapeLayer()
    private let head = CALayer()
    private let halo = CALayer()
    private let dot = CALayer()
    private let core = CALayer()
    private let ripple = CAShapeLayer()

    private var values: [Double] = []
    private var ceiling: Double = 1
    private var color: NSColor = .systemBlue
    private var showsGrid = true
    private var gridRows = 4
    private var gridColumns = 6
    private var lineWidth: CGFloat = 1.5
    private var decorated = true

    private static let duration: CFTimeInterval = 0.45

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        grid.fillColor = nil
        grid.lineWidth = 0.5
        layer?.addSublayer(grid)

        fill.mask = fillMask
        content.addSublayer(fill)
        glow.fillColor = nil
        glow.lineCap = .round
        glow.lineJoin = .round
        content.addSublayer(glow)
        strokeMask.fillColor = nil
        strokeMask.strokeColor = NSColor.black.cgColor
        strokeMask.lineCap = .round
        strokeMask.lineJoin = .round
        stroke.mask = strokeMask
        stroke.startPoint = CGPoint(x: 0, y: 0.5)
        stroke.endPoint = CGPoint(x: 1, y: 0.5)
        content.addSublayer(stroke)
        layer?.addSublayer(content)

        ripple.fillColor = nil
        ripple.lineWidth = 1.5
        ripple.opacity = 0
        for sublayer in [ripple, halo, dot, core] as [CALayer] { head.addSublayer(sublayer) }
        layer?.addSublayer(head)

        // 形や色を差し替えたときに Core Animation が勝手に付ける動きは使わない。
        let none: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(),
                                        "contents": NSNull(), "colors": NSNull(), "hidden": NSNull(),
                                        "strokeColor": NSNull(), "fillColor": NSNull(),
                                        "backgroundColor": NSNull(), "frame": NSNull(),
                                        "opacity": NSNull(), "lineWidth": NSNull(),
                                        "cornerRadius": NSNull()]
        for sublayer in [grid, content, fill, fillMask, glow, stroke, strokeMask,
                         head, halo, dot, core, ripple] as [CALayer] {
            sublayer.actions = none
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    func update(values newValues: [Double], ceiling newCeiling: Double, color newColor: NSColor,
                showsGrid: Bool, gridRows: Int, gridColumns: Int,
                lineWidth: CGFloat, decorated: Bool, animated: Bool) {
        let previousValues = values
        let previousHeadY = headY()
        let shifted = animated && !previousValues.isEmpty
            && previousValues.count == newValues.count && previousValues != newValues

        values = newValues
        ceiling = newCeiling
        color = newColor
        self.showsGrid = showsGrid
        self.gridRows = gridRows
        self.gridColumns = gridColumns
        self.lineWidth = lineWidth
        self.decorated = decorated
        rebuild()

        guard shifted, bounds.width > 0 else { return }
        let step = bounds.width / CGFloat(max(1, values.count - 1))

        // 1 目盛り右にずれた位置から本来の位置へ滑らせる（描き直しはしない）。
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = step
        slide.toValue = 0
        slide.duration = Self.duration
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        content.add(slide, forKey: "slide")

        guard decorated else { return }
        // 光点は前の高さから新しい高さへ移る。
        let move = CABasicAnimation(keyPath: "position.y")
        move.fromValue = previousHeadY
        move.toValue = headY()
        move.duration = Self.duration
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        head.add(move, forKey: "move")

        // 波紋が広がって消える。
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.4
        grow.toValue = 2.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.85
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = Self.duration * 1.6
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ripple.add(group, forKey: "ripple")
    }

    override func layout() {
        super.layout()
        rebuild()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    // MARK: - 形と色

    private func rebuild() {
        let size = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // ダーク／ライトで変わる色は、現在の外観で解決してから CGColor にする。
        var gridColor = NSColor.secondaryLabelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            gridColor = NSColor.secondaryLabelColor.withAlphaComponent(0.16).cgColor
        }
        let base = color.usingColorSpace(.deviceRGB) ?? color

        grid.frame = bounds
        grid.isHidden = !showsGrid
        grid.strokeColor = gridColor
        grid.path = showsGrid ? gridPath(in: size) : nil

        for sublayer in [content, fill, fillMask, glow, stroke, strokeMask] as [CALayer] {
            sublayer.frame = bounds
        }
        guard values.count > 1, size.width > 0, size.height > 0 else {
            fillMask.path = nil
            glow.path = nil
            strokeMask.path = nil
            head.isHidden = true
            return
        }

        let (line, area) = paths(in: size)
        fill.colors = [base.withAlphaComponent(0.42).cgColor, base.withAlphaComponent(0.02).cgColor]
        fillMask.path = area
        glow.isHidden = !decorated
        glow.path = line
        glow.strokeColor = base.withAlphaComponent(0.2).cgColor
        glow.lineWidth = lineWidth * 4
        stroke.colors = [base.withAlphaComponent(decorated ? 0.35 : 1).cgColor, base.cgColor]
        strokeMask.path = line
        strokeMask.lineWidth = lineWidth

        head.isHidden = !decorated
        head.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
        head.position = CGPoint(x: size.width - 3, y: headY())
        configure(halo, diameter: 11, color: base.withAlphaComponent(0.3))
        configure(dot, diameter: 5, color: base)
        configure(core, diameter: 2, color: NSColor.white.withAlphaComponent(0.85))
        ripple.frame = head.bounds
        ripple.path = CGPath(ellipseIn: head.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        ripple.strokeColor = base.withAlphaComponent(0.8).cgColor
    }

    private func configure(_ layer: CALayer, diameter: CGFloat, color: NSColor) {
        layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        layer.position = CGPoint(x: 7, y: 7)
        layer.cornerRadius = diameter / 2
        layer.backgroundColor = color.cgColor
    }

    private func headY() -> CGFloat {
        let ratio = ceiling > 0 ? min(1, max(0, (values.last ?? 0) / ceiling)) : 0
        return bounds.height * (1 - CGFloat(ratio))
    }

    private func paths(in size: CGSize) -> (line: CGPath, area: CGPath) {
        let step = size.width / CGFloat(values.count - 1)
        var points = values.indices.map { index -> CGPoint in
            let ratio = ceiling > 0 ? min(1, max(0, values[index] / ceiling)) : 0
            return CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(ratio)))
        }
        // 1 目盛り右にずらして滑り出す瞬間に左端が欠けないよう、
        // 画面の外（x = -step）に先頭の値をもう 1 つ置いておく。
        points.insert(CGPoint(x: -step, y: points[0].y), at: 0)
        // 隣り合う点の中点を通る 2 次曲線でつなぎ、折れ線を滑らかにする。
        let line = CGMutablePath()
        line.move(to: points[0])
        for index in 1..<points.count {
            let previous = points[index - 1]
            line.addQuadCurve(to: CGPoint(x: (previous.x + points[index].x) / 2,
                                          y: (previous.y + points[index].y) / 2),
                              control: previous)
        }
        line.addLine(to: points[points.count - 1])

        let area = line.mutableCopy() ?? CGMutablePath()
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: -step, y: size.height))
        area.closeSubpath()
        return (line, area)
    }

    private func gridPath(in size: CGSize) -> CGPath {
        let path = CGMutablePath()
        for row in 0...gridRows {
            let y = size.height * CGFloat(row) / CGFloat(max(1, gridRows))
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        for column in 0...gridColumns {
            let x = size.width * CGFloat(column) / CGFloat(max(1, gridColumns))
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        return path
    }
}

/// 送受信のように 2 系列を重ねて描くグラフ。縦軸は両系列で共有する。
struct DualMetricChart: View {
    var primary: [Double]
    var secondary: [Double]
    var primaryColor: Color
    var secondaryColor: Color
    var maxValue: Double?

    private var sharedCeiling: Double {
        if let maxValue { return maxValue }
        return ChartScale.ceiling(maxValue: nil, values: primary + secondary)
    }

    var body: some View {
        ZStack {
            MetricChart(values: primary, maxValue: sharedCeiling, color: primaryColor)
            MetricChart(values: secondary, maxValue: sharedCeiling, color: secondaryColor,
                        showsGrid: false)
        }
    }
}

/// サイドバーに置く小さなグラフ。発光・光点・流れる動きは付けない（小さすぎて見えないため）。
struct MiniChart: View {
    var values: [Double]
    var maxValue: Double?
    var color: Color

    var body: some View {
        MetricChart(values: values, maxValue: maxValue, color: color,
                    showsGrid: false, lineWidth: 1, decorated: false, animated: false)
            .frame(width: 46, height: 26)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.25), lineWidth: 0.5))
    }
}
