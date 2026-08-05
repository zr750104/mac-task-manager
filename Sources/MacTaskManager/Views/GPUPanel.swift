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
