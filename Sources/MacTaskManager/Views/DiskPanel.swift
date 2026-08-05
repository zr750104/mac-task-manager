import SwiftUI

struct DiskPanel: View {
    @EnvironmentObject private var engine: MetricsEngine

    var body: some View {
        let disk = engine.snapshot.disk

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: "ディスク",
                            subtitle: "全ブロックデバイスの合計 I/O",
                            value: Fmt.rate(disk.readRate + disk.writeRate),
                            valueColor: Palette.disk)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("転送速度").font(.headline)
                        Spacer()
                        LegendLabel(color: Palette.disk, text: "読み込み", value: Fmt.rate(disk.readRate))
                        LegendLabel(color: Palette.upload, text: "書き込み", value: Fmt.rate(disk.writeRate))
                    }
                    DualMetricChart(primary: engine.diskReadHistory.padded,
                                    secondary: engine.diskWriteHistory.padded,
                                    primaryColor: Palette.disk,
                                    secondaryColor: Palette.upload,
                                    maxValue: nil)
                        .frame(height: 170)
                }

                TileGrid(items: [
                    .init("読み込み", Fmt.rate(disk.readRate),
                          caption: "累計 \(Fmt.bytes(disk.totalRead))",
                          color: Palette.disk, emphasized: true),
                    .init("書き込み", Fmt.rate(disk.writeRate),
                          caption: "累計 \(Fmt.bytes(disk.totalWritten))",
                          color: Palette.upload, emphasized: true),
                    .init("読み込み回数/秒", Fmt.count(Int(disk.readsPerSec))),
                    .init("書き込み回数/秒", Fmt.count(Int(disk.writesPerSec)))
                ])

                VStack(alignment: .leading, spacing: 8) {
                    Text("物理ディスク").font(.headline)
                    ForEach(disk.disks) { drive in
                        HStack(spacing: 12) {
                            Image(systemName: drive.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                                .foregroundStyle(drive.isInternal ? Palette.disk : Palette.network)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(drive.displayName)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text("\(drive.bsdName) · \(drive.locationLabel) · 累計 \(Fmt.bytes(drive.totalRead)) 読 / \(Fmt.bytes(drive.totalWritten)) 書")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("読 \(Fmt.rate(drive.readRate))")
                                    .font(.callout).monospacedDigit()
                                    .foregroundStyle(Palette.disk)
                                Text("書 \(Fmt.rate(drive.writeRate))")
                                    .font(.callout).monospacedDigit()
                                    .foregroundStyle(Palette.upload)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("ボリューム").font(.headline)
                    ForEach(disk.volumes) { volume in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label(volume.name, systemImage: volume.path == "/"
                                      ? "internaldrive.fill" : "externaldrive.fill")
                                    .font(.callout.weight(.medium))
                                Spacer()
                                Text("\(Fmt.bytes(volume.used)) / \(Fmt.bytes(volume.total))")
                                    .font(.callout)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            UsageBar(ratio: volume.usedRatio,
                                     color: volume.usedRatio > 0.9 ? .red
                                          : (volume.usedRatio > 0.75 ? Palette.gpu : Palette.disk))
                            HStack {
                                Text(volume.path)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Text("空き \(Fmt.bytes(volume.free)) · 使用 \(Fmt.percent(volume.usedRatio, decimals: 0))")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
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
