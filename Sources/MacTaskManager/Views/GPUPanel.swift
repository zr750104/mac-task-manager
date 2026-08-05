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
                Text(Fmt.percent(ane.utilization))
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(ane.isActive ? Palette.efficiencyCore : .secondary)
            }

            // CPU / GPU と同じく 0〜100% の目盛りで推移を出す。
            MetricChart(values: engine.neuralEngineUtilizationHistory.padded, maxValue: 1,
                        color: Palette.efficiencyCore)
                .frame(height: 110)

            TileGrid(items: [
                .init("使用率", Fmt.percent(ane.utilization),
                      caption: String(format: "基準 %.2f W に対する比率", ane.referencePeak),
                      color: Palette.efficiencyCore, emphasized: true),
                .init("消費電力", String(format: "%.2f W", ane.watts),
                      caption: "動いていなければ 0 に近い値",
                      color: Palette.efficiencyCore, emphasized: true),
                .init("推論リクエスト/秒", Fmt.count(Int(ane.operationsPerSecond)),
                      caption: "ANE からの割り込み回数", emphasized: true)
            ], minimumWidth: 160)

            HStack(alignment: .top, spacing: 8) {
                Text("Apple は GPU の「デバイス使用率」に相当する NPU の稼働率を公開していません（root で powermetrics を動かしても電力しか出ません）。そのため使用率は消費電力を基準値で割って算出しています。基準の 2.0 W は、この Mac で Vision の画像分類を 8 スレッド並列で回したときの実測ピークです。これを超える電力を観測した場合は基準を自動で引き上げます。\n\nGPU 使用率は NPU の使用率ではありません。実測では NPU を全力で動かしている間も GPU 使用率は 22.3% → 25.2% とほとんど変化しませんでした。両者は別のハードウェアです。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("基準を戻す") {
                    NeuralEngineMonitor.resetReference()
                }
                .controlSize(.small)
                .help("使用率の基準を実測の既定値 2.0 W に戻します")
            }
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
