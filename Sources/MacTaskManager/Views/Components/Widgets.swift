import SwiftUI

/// 画面ごとのテーマカラー。
enum Palette {
    static let cpu = Color(red: 0.24, green: 0.55, blue: 0.95)
    static let performanceCore = Color(red: 0.95, green: 0.42, blue: 0.35)
    static let efficiencyCore = Color(red: 0.30, green: 0.72, blue: 0.62)
    static let memory = Color(red: 0.65, green: 0.42, blue: 0.92)
    static let gpu = Color(red: 0.95, green: 0.62, blue: 0.20)
    static let disk = Color(red: 0.35, green: 0.75, blue: 0.42)
    static let network = Color(red: 0.25, green: 0.72, blue: 0.85)
    static let upload = Color(red: 0.95, green: 0.50, blue: 0.60)
    static let temperature = Color(red: 0.95, green: 0.45, blue: 0.42)

    /// 温度に応じた色。Apple Silicon はおおむね 100℃ 付近で性能を落とす。
    static func heat(_ celsius: Double) -> Color {
        switch celsius {
        case ..<55: return disk
        case ..<70: return efficiencyCore
        case ..<85: return gpu
        case ..<95: return temperature
        default: return .red
        }
    }
}

/// StatTile を並べる。幅が狭いときは自動で折り返す。
struct TileGrid: View {
    struct Item: Identifiable {
        let id = UUID()
        var title: String
        var value: String
        var caption: String?
        var color: Color
        var emphasized: Bool

        init(_ title: String, _ value: String, caption: String? = nil,
             color: Color = .primary, emphasized: Bool = false) {
            self.title = title
            self.value = value
            self.caption = caption
            self.color = color
            self.emphasized = emphasized
        }
    }

    var items: [Item]
    var minimumWidth: CGFloat = 150

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: 10)],
                  spacing: 10) {
            ForEach(items) { item in
                StatTile(title: item.title, value: item.value, caption: item.caption,
                         color: item.color, emphasized: item.emphasized)
            }
        }
    }
}

/// 見出し + 大きな数値のタイル。
struct StatTile: View {
    var title: String
    var value: String
    var caption: String?
    var color: Color = .primary
    var emphasized: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(emphasized ? .system(size: 26, weight: .semibold, design: .rounded)
                                 : .system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 11)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
    }
}

/// 「ラベル ......... 値」の 1 行。
struct DetailRow: View {
    var label: String
    var value: String
    var color: Color?

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(color ?? .primary)
        }
    }
}

/// 使用率を示す横棒。
struct UsageBar: View {
    var ratio: Double
    var color: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, ratio)) * geometry.size.width)
            }
        }
        .frame(height: height)
    }
}

/// メモリの内訳のように、複数の区分を 1 本の帯で示す。
struct SegmentedBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        var label: String
        var value: Double
        var color: Color
    }

    var segments: [Segment]
    var total: Double
    var height: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: total > 0
                               ? max(0, segment.value / total) * (geometry.size.width - CGFloat(segments.count))
                               : 0)
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.08))
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// 凡例の丸印つきラベル。
struct LegendLabel: View {
    var color: Color
    var text: String
    var value: String?

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let value {
                Text(value)
                    .font(.caption)
                    .monospacedDigit()
            }
        }
    }
}

/// 画面上部の共通ヘッダー（タイトル・サブタイトル・現在値）。
struct PanelHeader: View {
    var title: String
    var subtitle: String
    var value: String
    var valueColor: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
    }
}

/// 論理コアごとの使用率を並べた小さなグリッド（P/E で色分け）。
struct CoreGrid: View {
    var histories: [History]
    var current: [Double]
    var clusters: [CoreCluster]
    /// 1 コアぶんのグラフの高さ。主役として出すときは大きくする。
    var chartHeight: CGFloat = 40
    /// 1 コアぶんの最小幅。大きくすると 1 行あたりの数が減る。
    var minimumWidth: CGFloat = 130

    private func color(for index: Int) -> Color {
        guard let cluster = clusters.first(where: { $0.range.contains(index) }) else { return Palette.cpu }
        return cluster.isPerformance ? Palette.performanceCore : Palette.efficiencyCore
    }

    private func label(for index: Int) -> String {
        guard let cluster = clusters.first(where: { $0.range.contains(index) }) else { return "CPU \(index)" }
        let offset = index - cluster.range.lowerBound
        return "\(cluster.isPerformance ? "P" : "E")\(offset)"
    }

    var body: some View {
        let isLarge = chartHeight >= 60
        let columns = [GridItem(.adaptive(minimum: minimumWidth, maximum: 320), spacing: 8)]
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(histories.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(label(for: index))
                            .font(isLarge ? .callout.weight(.semibold) : .caption2.weight(.semibold))
                            .foregroundStyle(color(for: index))
                        Spacer(minLength: 0)
                        Text(Fmt.percent(index < current.count ? current[index] : 0, decimals: 0))
                            .font(isLarge ? .callout.weight(.medium) : .caption2)
                            .monospacedDigit()
                            .foregroundStyle(isLarge ? .primary : .secondary)
                    }
                    MetricChart(values: histories[index].padded, maxValue: 1,
                                color: color(for: index), showsGrid: isLarge,
                                gridRows: 2, gridColumns: 3, lineWidth: isLarge ? 1.5 : 1)
                        .frame(height: chartHeight)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            }
        }
    }
}
