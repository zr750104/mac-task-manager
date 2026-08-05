import SwiftUI

struct NetworkPanel: View {
    @EnvironmentObject private var engine: MetricsEngine

    var body: some View {
        let network = engine.snapshot.network

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: "ネットワーク",
                            subtitle: "全インターフェースの合計",
                            value: Fmt.rate(network.downloadRate),
                            valueColor: Palette.network)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("通信速度").font(.headline)
                        Spacer()
                        LegendLabel(color: Palette.network, text: "受信", value: Fmt.rate(network.downloadRate))
                        LegendLabel(color: Palette.upload, text: "送信", value: Fmt.rate(network.uploadRate))
                    }
                    DualMetricChart(primary: engine.networkDownHistory.padded,
                                    secondary: engine.networkUpHistory.padded,
                                    primaryColor: Palette.network,
                                    secondaryColor: Palette.upload,
                                    maxValue: nil)
                        .frame(height: 170)
                }

                TileGrid(items: [
                    .init("受信", Fmt.rate(network.downloadRate),
                          caption: "累計 \(Fmt.bytes(network.totalReceived))",
                          color: Palette.network, emphasized: true),
                    .init("送信", Fmt.rate(network.uploadRate),
                          caption: "累計 \(Fmt.bytes(network.totalSent))",
                          color: Palette.upload, emphasized: true),
                    .init("受信パケット/秒", Fmt.count(Int(network.packetsInPerSec))),
                    .init("送信パケット/秒", Fmt.count(Int(network.packetsOutPerSec)))
                ])

                VStack(alignment: .leading, spacing: 8) {
                    Text("インターフェース").font(.headline)
                    if network.interfaces.isEmpty {
                        Text("通信中のインターフェースがありません。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(network.interfaces) { iface in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(iface.displayName).font(.callout.weight(.medium))
                                Text("累計 ↓ \(Fmt.bytes(iface.totalReceived)) · ↑ \(Fmt.bytes(iface.totalSent))")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("↓ \(Fmt.rate(iface.downloadRate))")
                                    .font(.callout).monospacedDigit()
                                    .foregroundStyle(Palette.network)
                                Text("↑ \(Fmt.rate(iface.uploadRate))")
                                    .font(.callout).monospacedDigit()
                                    .foregroundStyle(Palette.upload)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
                    }
                }
            }
        }
    }
}
