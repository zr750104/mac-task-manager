import SwiftUI

/// 時系列を塗りつぶし付きの折れ線で描くグラフ。
/// 左が過去・右が現在。Canvas 描画なので毎秒更新でも軽い。
struct MetricChart: View {
    var values: [Double]
    /// 縦軸の上限。nil なら実データから自動でスケールする。
    var maxValue: Double?
    var color: Color
    var showsGrid: Bool = true
    var gridRows: Int = 4
    var gridColumns: Int = 6
    var lineWidth: CGFloat = 1.5

    private var ceiling: Double {
        if let maxValue { return maxValue }
        let peak = values.max() ?? 0
        guard peak > 0 else { return 1 }
        // 自動スケールは「切りのいい値」に丸めて目盛りの跳ねを抑える。
        let magnitude = pow(10, floor(log10(peak)))
        let normalized = peak / magnitude
        let step: Double = normalized <= 1 ? 1 : (normalized <= 2 ? 2 : (normalized <= 5 ? 5 : 10))
        return step * magnitude
    }

    var body: some View {
        Canvas { context, size in
            if showsGrid { drawGrid(context: context, size: size) }
            guard values.count > 1, size.width > 0, size.height > 0 else { return }

            let top = ceiling
            let stepX = size.width / CGFloat(values.count - 1)
            func point(_ index: Int) -> CGPoint {
                let ratio = min(1, max(0, values[index] / top))
                return CGPoint(x: CGFloat(index) * stepX, y: size.height * (1 - ratio))
            }

            var line = Path()
            line.move(to: point(0))
            for index in 1..<values.count { line.addLine(to: point(index)) }

            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()

            context.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(0.45), color.opacity(0.05)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), lineWidth: lineWidth)
        }
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        var grid = Path()
        for row in 0...gridRows {
            let y = size.height * CGFloat(row) / CGFloat(gridRows)
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        for column in 0...gridColumns {
            let x = size.width * CGFloat(column) / CGFloat(gridColumns)
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
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
        let peak = max(primary.max() ?? 0, secondary.max() ?? 0)
        guard peak > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(peak)))
        let normalized = peak / magnitude
        let step: Double = normalized <= 1 ? 1 : (normalized <= 2 ? 2 : (normalized <= 5 ? 5 : 10))
        return step * magnitude
    }

    var body: some View {
        ZStack {
            MetricChart(values: primary, maxValue: sharedCeiling, color: primaryColor)
            MetricChart(values: secondary, maxValue: sharedCeiling, color: secondaryColor, showsGrid: false)
        }
    }
}

/// サイドバーに置く小さなグラフ。
struct MiniChart: View {
    var values: [Double]
    var maxValue: Double?
    var color: Color

    var body: some View {
        MetricChart(values: values, maxValue: maxValue, color: color,
                    showsGrid: false, lineWidth: 1)
            .frame(width: 46, height: 26)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.25), lineWidth: 0.5))
    }
}
