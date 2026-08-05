import SwiftUI

struct GPUPanel: View {
    @EnvironmentObject private var engine: MetricsEngine

    var body: some View {
        let gpu = engine.snapshot.gpu
        let info = engine.info

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: "GPU",
                            subtitle: "\(info.gpuName) · \(info.gpuCoreCount) コア",
                            value: gpu.available ? Fmt.percent(gpu.utilization) : "—",
                            valueColor: Palette.gpu)

                if gpu.available {
                    MetricChart(values: engine.gpuHistory.padded, maxValue: 1, color: Palette.gpu)
                        .frame(height: 170)

                    TileGrid(items: [
                        .init("デバイス使用率", Fmt.percent(gpu.utilization),
                              caption: "GPU 全体の稼働率", color: Palette.gpu, emphasized: true),
                        .init("レンダラ", Fmt.percent(gpu.renderer),
                              caption: "ピクセル処理", emphasized: true),
                        .init("タイラ", Fmt.percent(gpu.tiler),
                              caption: "ジオメトリ処理", emphasized: true)
                    ], minimumWidth: 170)

                    TileGrid(items: [
                        .init("使用中の GPU メモリ", Fmt.bytes(gpu.inUseMemory),
                              caption: "ユニファイドメモリから確保"),
                        .init("割り当て済み", Fmt.bytes(gpu.allocatedMemory),
                              caption: "ドライバが確保した総量"),
                        .init("物理メモリに占める割合",
                              info.memoryTotal > 0
                                ? Fmt.percent(Double(gpu.inUseMemory) / Double(info.memoryTotal))
                                : "—",
                              caption: "全 \(Fmt.bytes(info.memoryTotal))"),
                        .init("GPU 消費電力",
                              engine.snapshot.power.available
                                ? String(format: "%.2f W", engine.snapshot.power.gpu) : "—",
                              caption: engine.snapshot.power.available
                                ? String(format: "CPU は %.2f W", engine.snapshot.power.cpu) : nil,
                              color: Palette.gpu)
                    ])

                    neuralEngineSection

                    VStack(alignment: .leading, spacing: 8) {
                        Text("内訳").font(.headline)
                        VStack(spacing: 8) {
                            labeledBar("デバイス使用率", gpu.utilization, Palette.gpu)
                            labeledBar("レンダラ使用率", gpu.renderer, Palette.performanceCore)
                            labeledBar("タイラ使用率", gpu.tiler, Palette.efficiencyCore)
                        }
                    }

                    Text("Apple Silicon は CPU と GPU が同じメモリを共有するユニファイドメモリ構成のため、GPU メモリは物理メモリから確保されます。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                } else {
                    ContentUnavailableView("GPU の情報を取得できませんでした",
                                           systemImage: "cube.transparent",
                                           description: Text("IOAccelerator から統計情報が公開されていません。"))
                        .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
        }
    }

    /// Neural Engine（NPU）。Apple は GPU のような使用率を公開していないため、
    /// 実測で確実に反応することを確認した「消費電力」と「割り込み回数」を指標にしている。
    private var neuralEngineSection: some View {
        let ane = engine.snapshot.neuralEngine
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Neural Engine（NPU）").font(.headline)
                Text(ane.stateLabel)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(ane.isActive ? Palette.efficiencyCore.opacity(0.3)
                              : Color.secondary.opacity(0.2)))
                Spacer()
                Text(String(format: "%.2f W", ane.watts))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(ane.isActive ? Palette.efficiencyCore : .secondary)
            }

            MetricChart(values: engine.neuralEngineHistory.padded, maxValue: nil,
                        color: Palette.efficiencyCore)
                .frame(height: 90)

            TileGrid(items: [
                .init("消費電力", String(format: "%.2f W", ane.watts),
                      caption: "動いていなければ 0 に近い値",
                      color: Palette.efficiencyCore, emphasized: true),
                .init("使用率の目安", Fmt.percent(ane.utilization),
                      caption: String(format: "観測した最大 %.2f W に対する比率", ane.referencePeak),
                      color: Palette.efficiencyCore, emphasized: true),
                .init("推論リクエスト/秒", Fmt.count(Int(ane.operationsPerSecond)),
                      caption: "ANE からの割り込み回数", emphasized: true)
            ], minimumWidth: 160)

            Text("Apple は GPU の「デバイス使用率」に相当する NPU の稼働率を公開していません。ここでは実機で Vision の画像分類を実行し、確実に反応することを確認できた消費電力（アイドル 0.005 W → 負荷時 1.52 W）と割り込み回数を表示しています。使用率は起動後に観測した最大電力に対する比率で、絶対的な稼働率ではありません。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
    }

    private func labeledBar(_ title: String, _ ratio: Double, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            UsageBar(ratio: ratio, color: color)
            Text(Fmt.percent(ratio))
                .font(.callout)
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
        }
    }
}
