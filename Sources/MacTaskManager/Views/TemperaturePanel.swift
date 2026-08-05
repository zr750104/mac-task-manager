import SwiftUI

struct TemperaturePanel: View {
    @EnvironmentObject private var engine: MetricsEngine

    /// グラフの縦軸。Apple Silicon はおおむね 100℃ 付近で性能を落とすため上限を固定して余裕が見えるようにする。
    private let ceiling: Double = 110

    var body: some View {
        let temperature = engine.temperature
        let power = engine.snapshot.power

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: "温度・電力",
                            subtitle: temperature.available
                                ? "\(engine.info.chipName) · センサー \(temperature.sensors.count) 個"
                                : "温度センサー",
                            value: temperature.available
                                ? String(format: "%.1f ℃", temperature.socMax) : "—",
                            valueColor: Palette.heat(temperature.socMax))

                if temperature.available {
                    MetricChart(values: engine.temperatureHistory.padded,
                                maxValue: ceiling,
                                color: Palette.heat(temperature.socMax))
                        .frame(height: 150)
                        .overlay(alignment: .topLeading) {
                            Text("\(Int(ceiling)) ℃").font(.caption2)
                                .foregroundStyle(.tertiary).padding(4)
                        }

                    TileGrid(items: temperatureTiles, minimumWidth: 170)
                } else {
                    ContentUnavailableView("温度を取得できませんでした",
                                           systemImage: "thermometer.medium.slash",
                                           description: Text("この Mac では温度センサーが公開されていません。"))
                        .frame(maxWidth: .infinity, minHeight: 160)
                }

                if power.available {
                    powerSection(power)
                }

                if engine.battery.available {
                    batterySection(engine.battery)
                }

                if temperature.available {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("センサー別").font(.headline)
                        ForEach(temperature.categories, id: \.rawValue) { category in
                            categorySection(category, sensors: temperature.sensors(in: category))
                        }
                    }
                }

                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - 温度

    private var temperatureTiles: [TileGrid.Item] {
        let temperature = engine.temperature
        var items: [TileGrid.Item] = [
            .init("チップ最高温度", String(format: "%.1f ℃", temperature.socMax),
                  caption: thermalCaption,
                  color: Palette.heat(temperature.socMax), emphasized: true),
            .init("チップ平均温度", String(format: "%.1f ℃", temperature.socAverage),
                  caption: "ダイ上センサーの平均",
                  color: Palette.heat(temperature.socAverage), emphasized: true)
        ]
        if let storage = temperature.max(in: .storage) {
            items.append(.init("SSD 温度", String(format: "%.1f ℃", storage),
                               caption: "内蔵ストレージ",
                               color: Palette.heat(storage), emphasized: true))
        }
        items.append(.init("サーマル状態", engine.thermalState.label,
                           caption: "OS の判定",
                           color: engine.thermalState == .nominal ? .primary : .orange,
                           emphasized: true))
        return items
    }

    private var thermalCaption: String {
        switch engine.temperature.socMax {
        case ..<60: return "余裕があります"
        case ..<80: return "通常の動作範囲です"
        case ..<95: return "高負荷が続いています"
        default: return "性能が制限される可能性があります"
        }
    }

    // MARK: - 電力

    private func powerSection(_ power: PowerSample) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("消費電力").font(.headline)
                Spacer()
                Text("CPU と GPU は同じダイのため温度では分離できませんが、電力は個別に測れます")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            TileGrid(items: powerTiles(power), minimumWidth: 150)

            VStack(spacing: 8) {
                powerBar("CPU", power.cpu, Palette.cpu, of: power)
                powerBar("GPU", power.gpu, Palette.gpu, of: power)
                if power.dram > 0 { powerBar("メモリ (DRAM)", power.dram, Palette.memory, of: power) }
                if power.neuralEngine > 0 {
                    powerBar("Neural Engine", power.neuralEngine, Palette.efficiencyCore, of: power)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
    }

    private func powerTiles(_ power: PowerSample) -> [TileGrid.Item] {
        var items: [TileGrid.Item] = [
            .init("CPU", String(format: "%.2f W", power.cpu),
                  caption: String(format: "P %.2f W / E %.2f W",
                                  power.performanceCores, power.efficiencyCores),
                  color: Palette.cpu, emphasized: true),
            .init("GPU", String(format: "%.2f W", power.gpu),
                  caption: "\(engine.info.gpuCoreCount) コア",
                  color: Palette.gpu, emphasized: true)
        ]
        if power.dram > 0 {
            items.append(.init("メモリ", String(format: "%.2f W", power.dram),
                               caption: "DRAM", color: Palette.memory, emphasized: true))
        }
        items.append(.init("主要ブロック合計", String(format: "%.2f W", power.majorTotal),
                           caption: "CPU + GPU + メモリ", emphasized: true))
        return items
    }

    private func powerBar(_ title: String, _ watts: Double,
                          _ color: Color, of power: PowerSample) -> some View {
        // 目盛りは主要ブロックのうち最大のものに合わせる。
        let scale = max(power.cpu, power.gpu, power.dram, power.neuralEngine, 1)
        return HStack(spacing: 10) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)
            UsageBar(ratio: watts / scale, color: color)
            Text(String(format: "%.2f W", watts))
                .font(.callout)
                .monospacedDigit()
                .frame(width: 66, alignment: .trailing)
        }
    }

    // MARK: - バッテリー

    private func batterySection(_ battery: BatterySample) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("バッテリー").font(.headline)
                Spacer()
                Text(battery.stateLabel)
                    .font(.caption)
                    .foregroundStyle(battery.isPluggedIn ? Palette.disk : .secondary)
            }
            UsageBar(ratio: battery.charge,
                     color: battery.charge < 0.2 && !battery.isPluggedIn ? .red : Palette.disk,
                     height: 10)
            TileGrid(items: batteryTiles(battery), minimumWidth: 140)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
    }

    private func batteryTiles(_ battery: BatterySample) -> [TileGrid.Item] {
        var items: [TileGrid.Item] = [
            .init("残量", String(format: "%.0f%%", battery.charge * 100),
                  caption: battery.stateLabel, color: Palette.disk, emphasized: true)
        ]
        if let minutes = battery.minutesRemaining {
            items.append(.init(battery.isCharging ? "満充電まで" : "残り時間",
                               String(format: "%d:%02d", minutes / 60, minutes % 60),
                               caption: "時間:分", emphasized: true))
        }
        items.append(.init("消費/充電電力", String(format: "%+.2f W", battery.wattage),
                           caption: String(format: "%.2f V", battery.voltage), emphasized: true))
        items.append(.init("バッテリー状態", battery.healthLabel,
                           caption: "\(battery.cycleCount) 回充電 · \(battery.condition)",
                           emphasized: true))
        if let temperature = battery.temperature {
            items.append(.init("バッテリー温度", String(format: "%.1f ℃", temperature),
                               color: Palette.heat(temperature), emphasized: true))
        }
        return items
    }

    // MARK: - センサー一覧

    private func categorySection(_ category: SensorCategory,
                                 sensors: [TemperatureSensor]) -> some View {
        let peak = sensors.map(\.celsius).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(category.label)
                    .font(.callout.weight(.medium))
                Text("\(sensors.count) 個")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(String(format: "最高 %.1f ℃", peak))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(Palette.heat(peak))
            }
            if let note = category.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 6)], spacing: 6) {
                ForEach(sensors) { sensor in
                    HStack(spacing: 8) {
                        Text(sensor.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        UsageBar(ratio: sensor.celsius / ceiling,
                                 color: Palette.heat(sensor.celsius), height: 5)
                            .frame(width: 42)
                        Text(String(format: "%.1f℃", sensor.celsius))
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
    }

    private var footnote: String {
        var lines = [
            "センサー名はチップの世代によって異なります。tdie はダイ（チップ本体）の温度、tdev は電源まわりの温度です。"
        ]
        if engine.temperature.sensors(in: .performanceCore).isEmpty
            && engine.temperature.sensors(in: .gpu).isEmpty {
            lines.append("この Mac は CPU / GPU 個別の温度センサーを公開していないため、ダイ全体の温度を表示しています。CPU と GPU のどちらが働いているかは上の「消費電力」で判別できます。")
        }
        lines.append("ファン回転数はこの Mac では公開されていないため表示できません。")
        return lines.joined(separator: "\n")
    }
}
