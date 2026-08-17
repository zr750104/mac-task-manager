import SwiftUI

/// CPU のグラフ表示。Windows のタスクマネージャーと同じく、
/// 全体を 1 本で見るか、論理コアごとに分けて見るかを切り替えられる。
enum CPUGraphMode: String, CaseIterable, Identifiable {
    case total
    case perCore

    var id: String { rawValue }
    var label: String {
        switch self {
        case .total: return "全体"
        case .perCore: return "コア別"
        }
    }
}

struct CPUPanel: View {
    @EnvironmentObject private var engine: MetricsEngine
    /// 選んだ表示は次回起動時も引き継ぐ。
    @AppStorage("cpuGraphMode") private var graphMode: CPUGraphMode = .total

    var body: some View {
        let cpu = engine.snapshot.cpu
        let info = engine.info

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: "CPU",
                            subtitle: "\(info.chipName) · \(info.logicalCores) 論理コア（P \(info.performanceCoreCount) / E \(info.efficiencyCoreCount)）",
                            value: Fmt.percent(cpu.total),
                            valueColor: Palette.cpu)

                HStack {
                    Picker("表示", selection: $graphMode) {
                        ForEach(CPUGraphMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)

                    if graphMode == .perCore {
                        Text("E コアと P コアで色を分けています")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text("直近 \(historySeconds) 秒")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                switch graphMode {
                case .total:
                    MetricChart(values: engine.cpuHistory.padded, maxValue: 1, color: Palette.cpu)
                        .frame(height: 170)
                        .overlay(alignment: .topLeading) {
                            Text("100%").font(.caption2).foregroundStyle(.tertiary).padding(4)
                        }
                case .perCore:
                    CoreGrid(histories: engine.coreHistories,
                             current: cpu.perCore,
                             clusters: info.clusters,
                             chartHeight: 78,
                             minimumWidth: 190)
                }

                TileGrid(items: [
                    .init("全体", Fmt.percent(cpu.total),
                          caption: "ユーザ \(Fmt.percent(cpu.user, decimals: 0)) / システム \(Fmt.percent(cpu.system, decimals: 0))",
                          color: Palette.cpu, emphasized: true)
                ] + info.clusters.enumerated().map { index, cluster in
                    .init(cluster.displayName,
                          Fmt.percent(index < cpu.perCluster.count ? cpu.perCluster[index] : 0),
                          caption: "\(cluster.logicalCount) コア · \(cluster.name)",
                          color: cluster.isPerformance ? Palette.performanceCore : Palette.efficiencyCore,
                          emphasized: true)
                }, minimumWidth: 170)

                TileGrid(items: [
                    .init("アイドル", Fmt.percent(cpu.idle)),
                    .init("ロードアベレージ",
                          cpu.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "),
                          caption: "1分 / 5分 / 15分"),
                    .init("チップ温度",
                          engine.temperature.available
                            ? String(format: "%.1f ℃", engine.temperature.socMax) : "—",
                          caption: "サーマル状態: \(engine.thermalState.label)",
                          color: engine.temperature.available
                            ? Palette.heat(engine.temperature.socMax) : .primary),
                    .init("CPU 消費電力",
                          engine.snapshot.power.available
                            ? String(format: "%.2f W", engine.snapshot.power.cpu) : "—",
                          caption: engine.snapshot.power.available
                            ? String(format: "P %.2f W / E %.2f W",
                                     engine.snapshot.power.performanceCores,
                                     engine.snapshot.power.efficiencyCores)
                            : nil,
                          color: Palette.cpu)
                ])

                // クラスタ別の推移
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("クラスタ別の推移").font(.headline)
                        Spacer()
                        ForEach(Array(info.clusters.enumerated()), id: \.element.id) { index, cluster in
                            LegendLabel(color: cluster.isPerformance ? Palette.performanceCore : Palette.efficiencyCore,
                                        text: cluster.displayName,
                                        value: Fmt.percent(index < cpu.perCluster.count ? cpu.perCluster[index] : 0, decimals: 0))
                        }
                    }
                    ZStack {
                        ForEach(Array(engine.cpuClusterHistory.enumerated()), id: \.offset) { index, history in
                            let cluster = index < info.clusters.count ? info.clusters[index] : nil
                            MetricChart(values: history.padded, maxValue: 1,
                                        color: (cluster?.isPerformance ?? true)
                                            ? Palette.performanceCore : Palette.efficiencyCore,
                                        showsGrid: index == 0)
                        }
                    }
                    .frame(height: 130)
                }

                // 「全体」表示のときだけ、コア別を小さく併記する。
                // 「コア別」表示では上部がすでにコア別なので重複させない。
                if graphMode == .total {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("論理コアごとの使用率（\(info.logicalCores) コア）").font(.headline)
                            Spacer()
                            Button("大きく見る") { graphMode = .perCore }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                        CoreGrid(histories: engine.coreHistories,
                                 current: cpu.perCore,
                                 clusters: info.clusters)
                    }
                }
            }
        }
    }

    private var historySeconds: Int {
        Int(Double(MetricsEngine.historyLength) * engine.refreshRate.rawValue)
    }
}
