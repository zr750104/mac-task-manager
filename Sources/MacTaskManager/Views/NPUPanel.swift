import SwiftUI

/// Neural Engine（NPU）の画面。
///
/// GPU と同じダイに載ってはいるが**まったく別のハードウェア**なので、独立した画面にしている。
/// 実測でも NPU を全力で動かしている間、GPU 使用率は 22.3% → 25.2% とほぼ変化しなかった。
struct NPUPanel: View {
    @EnvironmentObject private var engine: MetricsEngine

    var body: some View {
        let ane = engine.snapshot.neuralEngine
        let gpu = engine.snapshot.gpu

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: "NPU（Neural Engine）",
                            subtitle: "\(engine.info.chipName) の機械学習用アクセラレータ",
                            value: Fmt.percent(ane.utilization),
                            valueColor: ane.isActive ? Palette.efficiencyCore : .secondary)

                // CPU / GPU と同じく 0〜100% の目盛りで推移を出す。
                MetricChart(values: engine.neuralEngineUtilizationHistory.padded, maxValue: 1,
                            color: Palette.efficiencyCore)
                    .frame(height: 170)

                TileGrid(items: [
                    .init("使用率", Fmt.percent(ane.utilization),
                          caption: String(format: "基準 %.2f W に対する比率", ane.referencePeak),
                          color: Palette.efficiencyCore, emphasized: true),
                    .init("状態", ane.stateLabel,
                          caption: "推論が動いているか",
                          color: ane.isActive ? Palette.efficiencyCore : .primary, emphasized: true),
                    .init("消費電力", String(format: "%.2f W", ane.watts),
                          caption: "動いていなければ 0 に近い値",
                          color: Palette.efficiencyCore, emphasized: true),
                    .init("推論リクエスト/秒", Fmt.count(Int(ane.operationsPerSecond)),
                          caption: "ANE からの割り込み回数", emphasized: true)
                ], minimumWidth: 160)

                // GPU と混同されやすいので、同じ画面で並べて比較できるようにしておく。
                VStack(alignment: .leading, spacing: 8) {
                    Text("GPU との比較").font(.headline)
                    Text("NPU と GPU は同じチップに載っていますが、別々のハードウェアです。片方が動いても、もう片方の使用率は上がりません。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 8) {
                        comparisonBar("NPU（機械学習）", ane.utilization, Palette.efficiencyCore)
                        comparisonBar("GPU（グラフィックス）",
                                      gpu.available ? gpu.utilization : 0, Palette.gpu)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))

                measurementNotes
            }
        }
    }

    private func comparisonBar(_ title: String, _ ratio: Double, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
                .lineLimit(1)
            UsageBar(ratio: ratio, color: color)
            Text(Fmt.percent(ratio))
                .font(.callout)
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
        }
    }

    private var measurementNotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("使用率の求め方").font(.headline)
                Spacer()
                Button("基準を戻す") {
                    NeuralEngineMonitor.resetReference()
                }
                .controlSize(.small)
                .help("使用率の基準を実測の既定値 2.0 W に戻します")
            }
            Text("""
            Apple は GPU の「デバイス使用率」に相当する NPU の稼働率を公開していません（root で powermetrics を動かしても電力しか出ず、IOReport にも動作周波数ごとの滞留時間は含まれていません）。

            そのため使用率は「消費電力 ÷ 基準電力」で算出しています。基準の 2.0 W は、この Mac で Vision の画像分類を 8 スレッド並列で回したときの実測ピークです。これを超える電力を観測した場合は基準を自動で引き上げ、次回起動時も引き継ぎます。

            ハードウェアが報告する稼働率そのものではありませんが、CPU 使用率と同じ感覚で読める値になります。
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
    }
}
