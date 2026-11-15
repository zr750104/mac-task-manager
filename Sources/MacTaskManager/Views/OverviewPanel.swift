import SwiftUI

struct OverviewPanel: View {
    @EnvironmentObject private var engine: MetricsEngine
    @Binding var selection: Panel

    /// 1 枚のカード。高さに余裕があるほど段階的に情報を増やす。
    private struct Card: Identifiable {
        var id: String { title + panel.rawValue }
        var panel: Panel
        /// 既定では panel.title を使うが、1 つの画面に複数カードを割り当てる場合に上書きする。
        var title: String
        var icon: String
        var color: Color
        var value: String
        /// カード中央に出す小見出し付きの数値（2〜3 個）
        var details: [(String, String)]
        /// 最下段の 1 行
        var caption: String
        var content: AnyView
    }

    var body: some View {
        GeometryReader { geometry in
            let cards = cards
            let spacing: CGFloat = 8
            let columns = columnCount(for: geometry.size.width)
            let rows = max(1, Int(ceil(Double(cards.count) / Double(columns))))
            let headerHeight: CGFloat = 40
            let available = geometry.size.height - headerHeight - spacing * CGFloat(rows)
            // 情報量が増えたぶん、詰め込みすぎないよう下限を設けている。
            // 下限に達したときだけスクロールに切り替わる。
            let cardHeight = max(88, available / CGFloat(rows))
            let fits = cardHeight * CGFloat(rows) + spacing * CGFloat(rows) + headerHeight
                <= geometry.size.height + 1

            VStack(alignment: .leading, spacing: spacing) {
                header.frame(height: headerHeight - spacing)
                let grid = LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: spacing),
                                   count: columns),
                    spacing: spacing) {
                        ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                            OverviewCard(index: index, color: card.color) {
                                cardView(card, height: cardHeight)
                            }
                        }
                    }
                if fits {
                    grid
                } else {
                    ScrollView { grid }
                }
            }
        }
    }

    /// 列数。カードは 10 枚（ノート型はバッテリーを加えて 11 枚）。
    /// 1 枚のカードが狭くなりすぎないよう、3 列を使う幅を広めに取っている。
    private func columnCount(for width: CGFloat) -> Int {
        switch width {
        case ..<300: return 1
        case ..<620: return 2
        case ..<1100: return 3
        default: return 4
        }
    }

    // MARK: - カード定義

    private var cards: [Card] {
        let snapshot = engine.snapshot
        var list: [Card] = []

        // CPU
        let cpu = snapshot.cpu
        list.append(Card(
            panel: .cpu, title: "CPU", icon: "cpu", color: Palette.cpu,
            value: Fmt.percent(cpu.total),
            details: engine.info.clusters.enumerated().map { index, cluster in
                (cluster.displayName,
                 Fmt.percent(index < cpu.perCluster.count ? cpu.perCluster[index] : 0, decimals: 0))
            } + [("負荷", String(format: "%.2f", cpu.loadAverage.first ?? 0))],
            caption: "ユーザ \(Fmt.percent(cpu.user, decimals: 0)) · システム \(Fmt.percent(cpu.system, decimals: 0)) · アイドル \(Fmt.percent(cpu.idle, decimals: 0))",
            content: AnyView(MetricChart(values: engine.cpuHistory.padded, maxValue: 1,
                                         color: Palette.cpu, gridRows: 2, gridColumns: 4))))

        // メモリ
        let memory = snapshot.memory
        list.append(Card(
            panel: .memory, title: "メモリ", icon: "memorychip", color: Palette.memory,
            value: Fmt.percent(memory.usedRatio),
            details: [("使用中", Fmt.bytes(memory.used)),
                      ("空き", Fmt.bytes(memory.free)),
                      ("スワップ", Fmt.bytes(memory.swapUsed))],
            caption: "圧縮 \(Fmt.bytes(memory.compressed)) · 確保済み \(Fmt.bytes(memory.wired)) · プレッシャー \(memory.pressureLevel.label)",
            content: AnyView(MetricChart(values: engine.memoryHistory.padded, maxValue: 1,
                                         color: Palette.memory, gridRows: 2, gridColumns: 4))))

        // GPU
        let gpu = snapshot.gpu
        list.append(Card(
            panel: .gpu, title: "GPU", icon: "cube.transparent", color: Palette.gpu,
            value: gpu.available ? Fmt.percent(gpu.utilization) : "—",
            details: [("レンダラ", Fmt.percent(gpu.renderer, decimals: 0)),
                      ("タイラ", Fmt.percent(gpu.tiler, decimals: 0)),
                      ("メモリ", Fmt.bytes(gpu.inUseMemory))],
            caption: "\(engine.info.gpuCoreCount) コア · 割り当て \(Fmt.bytes(gpu.allocatedMemory))",
            content: AnyView(MetricChart(values: engine.gpuHistory.padded, maxValue: 1,
                                         color: Palette.gpu, gridRows: 2, gridColumns: 4))))

        // 温度
        let temperature = engine.temperature
        list.append(Card(
            panel: .temperature, title: "温度", icon: "thermometer.medium",
            color: Palette.heat(temperature.socMax),
            value: temperature.available ? String(format: "%.1f ℃", temperature.socMax) : "—",
            details: [("平均", temperature.available
                       ? String(format: "%.0f℃", temperature.socAverage) : "—"),
                      ("SSD", temperature.max(in: .storage).map { String(format: "%.0f℃", $0) } ?? "—"),
                      ("状態", engine.thermalState.label)],
            caption: temperature.available
                ? "センサー \(temperature.sensors.count) 個 · ダイ最高 \(String(format: "%.1f℃", temperature.socMax))"
                : "温度センサーを取得できません",
            content: AnyView(MetricChart(values: engine.temperatureHistory.padded, maxValue: 110,
                                         color: Palette.heat(temperature.socMax),
                                         gridRows: 2, gridColumns: 4))))

        // 電力
        let power = snapshot.power
        list.append(Card(
            panel: .temperature, title: "消費電力", icon: "bolt.fill", color: Palette.gpu,
            value: power.available ? String(format: "%.2f W", power.cpu + power.gpu) : "—",
            details: [("CPU", String(format: "%.2fW", power.cpu)),
                      ("GPU", String(format: "%.2fW", power.gpu)),
                      ("メモリ", String(format: "%.2fW", power.dram))],
            caption: power.available
                ? String(format: "P コア %.2fW · E コア %.2fW", power.performanceCores, power.efficiencyCores)
                : "消費電力を取得できません",
            content: AnyView(MetricChart(values: engine.powerHistory.padded, maxValue: nil,
                                         color: Palette.gpu, gridRows: 2, gridColumns: 4))))

        // Neural Engine（NPU）
        let ane = snapshot.neuralEngine
        list.append(Card(
            panel: .npu, title: "NPU (Neural Engine)", icon: "brain", color: Palette.efficiencyCore,
            value: Fmt.percent(ane.utilization),
            details: [("状態", ane.stateLabel),
                      ("消費電力", String(format: "%.2fW", ane.watts)),
                      ("推論/秒", Fmt.count(Int(ane.operationsPerSecond)))],
            caption: String(format: "基準 %.2f W に対する比率 · GPU 使用率とは別物です", ane.referencePeak),
            content: AnyView(MetricChart(values: engine.neuralEngineUtilizationHistory.padded,
                                         maxValue: 1, color: Palette.efficiencyCore,
                                         gridRows: 2, gridColumns: 4))))

        // ディスク
        let disk = snapshot.disk
        list.append(Card(
            panel: .disk, title: "ディスク", icon: "internaldrive", color: Palette.disk,
            value: Fmt.rate(disk.readRate + disk.writeRate),
            details: [("読み", Fmt.rate(disk.readRate)),
                      ("書き", Fmt.rate(disk.writeRate)),
                      ("IOPS", Fmt.count(Int(disk.readsPerSec + disk.writesPerSec)))],
            caption: diskCaption,
            content: AnyView(DualMetricChart(primary: engine.diskReadHistory.padded,
                                             secondary: engine.diskWriteHistory.padded,
                                             primaryColor: Palette.disk,
                                             secondaryColor: Palette.upload, maxValue: nil))))

        // ネットワーク
        let network = snapshot.network
        list.append(Card(
            panel: .network, title: "ネットワーク", icon: "network", color: Palette.network,
            value: Fmt.rate(network.downloadRate + network.uploadRate),
            details: [("受信", Fmt.rate(network.downloadRate)),
                      ("送信", Fmt.rate(network.uploadRate)),
                      ("パケット/秒", Fmt.count(Int(network.packetsInPerSec + network.packetsOutPerSec)))],
            caption: "累計 ↓\(Fmt.bytes(network.totalReceived)) · ↑\(Fmt.bytes(network.totalSent))",
            content: AnyView(DualMetricChart(primary: engine.networkDownHistory.padded,
                                             secondary: engine.networkUpHistory.padded,
                                             primaryColor: Palette.network,
                                             secondaryColor: Palette.upload, maxValue: nil))))

        // 上位プロセス
        let top = engine.topProcesses(by: \.cpuPercent, limit: 4)
        list.append(Card(
            panel: .processes, title: "CPU 使用率の高いプロセス", icon: "list.bullet.rectangle",
            color: Palette.cpu,
            value: engine.processes.isEmpty ? "—" : "\(engine.processes.count)",
            details: [],
            caption: engine.processes.isEmpty
                ? "収集中…"
                : "全 \(engine.processes.count) プロセス · スレッド \(Fmt.count(engine.processes.reduce(0) { $0 + $1.threads }))",
            content: AnyView(processList(top))))

        // ストレージ容量
        list.append(Card(
            panel: .disk, title: "ストレージ", icon: "externaldrive", color: Palette.disk,
            value: storageValue,
            details: [],
            caption: "ボリューム \(disk.volumes.count) 個 · 物理ディスク \(disk.disks.count) 台",
            content: AnyView(volumeList(disk.volumes))))

        // バッテリー（ノート型のみ）
        let battery = engine.battery
        if battery.available {
            list.append(Card(
                panel: .temperature, title: "バッテリー", icon: "battery.100", color: Palette.disk,
                value: String(format: "%.0f%%", battery.charge * 100),
                details: [("状態", battery.stateLabel),
                          ("電力", String(format: "%+.1fW", battery.wattage)),
                          ("劣化", battery.healthLabel)],
                caption: "\(battery.cycleCount) 回充電 · \(battery.condition)"
                    + (battery.temperature.map { String(format: " · %.0f℃", $0) } ?? ""),
                content: AnyView(batteryGauge(battery))))
        }

        return list
    }

    private var diskCaption: String {
        let disks = engine.snapshot.disk.disks
        guard !disks.isEmpty else { return "累計 \(Fmt.bytes(engine.snapshot.disk.totalRead)) 読み込み" }
        return disks.prefix(3)
            .map { "\($0.bsdName) \(Fmt.rate($0.readRate + $0.writeRate))" }
            .joined(separator: " · ")
    }

    private var storageValue: String {
        guard let boot = engine.snapshot.disk.volumes.first else { return "—" }
        return Fmt.bytes(boot.free) + " 空き"
    }

    // MARK: - カード内の可変コンテンツ

    private func processList(_ rows: [ProcessRow]) -> some View {
        VStack(spacing: 2) {
            if rows.isEmpty {
                Spacer()
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        AppIconView(bundlePath: row.appBundlePath,
                                    isApp: row.isGUIApp, size: 13)
                        Text(row.name)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(Fmt.bytes(row.memory))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                        Text(Fmt.cpuPercent(row.cpuPercent))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(Palette.cpu)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func volumeList(_ volumes: [VolumeInfo]) -> some View {
        VStack(spacing: 3) {
            ForEach(Array(volumes.prefix(3))) { volume in
                VStack(spacing: 1) {
                    HStack(spacing: 6) {
                        Text(volume.name)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text("\(Fmt.bytes(volume.free)) 空き")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    UsageBar(ratio: volume.usedRatio, color: Palette.disk, height: 4)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func batteryGauge(_ battery: BatterySample) -> some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            UsageBar(ratio: battery.charge,
                     color: battery.charge < 0.2 && !battery.isPluggedIn ? .red : Palette.disk,
                     height: 10)
            if let minutes = battery.minutesRemaining {
                Text(battery.isCharging
                     ? String(format: "満充電まで %d:%02d", minutes / 60, minutes % 60)
                     : String(format: "残り %d:%02d", minutes / 60, minutes % 60))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 部品

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(engine.info.marketingName)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(engine.info.chipName) · \(engine.info.logicalCores) コア（P \(engine.info.performanceCoreCount) / E \(engine.info.efficiencyCoreCount)） · GPU \(engine.info.gpuCoreCount) コア · \(Fmt.bytes(engine.info.memoryTotal)) · \(engine.info.osVersion) · 稼働 \(Fmt.duration(engine.info.uptime))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 4)
            Button {
                selection = .processes
            } label: {
                ViewThatFits(in: .horizontal) {
                    Label("プロセス", systemImage: "list.bullet.rectangle")
                    Image(systemName: "list.bullet.rectangle")
                }
            }
            .buttonStyle(.bordered)
            .fixedSize()
        }
    }

    private func cardView(_ card: Card, height: CGFloat) -> some View {
        // 高さに応じて出す情報を切り替える。狭いときは値とグラフだけにする。
        let showsDetails = height >= 150 && !card.details.isEmpty
        let showsCaption = height >= 118

        return Button {
            selection = card.panel
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: card.icon)
                        .font(.caption2)
                        .foregroundStyle(card.color)
                    Text(card.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(card.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 2)
                    Text(card.value)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }

                card.content
                    .frame(maxHeight: .infinity)

                if showsDetails {
                    HStack(spacing: 0) {
                        ForEach(Array(card.details.enumerated()), id: \.offset) { _, detail in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(detail.0)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                Text(detail.1)
                                    .font(.caption2.weight(.medium))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if showsCaption {
                    Text(card.caption)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
            }
            .padding(8)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [card.color.opacity(0.10), Color.primary.opacity(0.035)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// 概要のカード 1 枚ぶんの演出。
/// - 画面を開いたとき、左上から順に少しずつ遅れてふわっと現れる
/// - カーソルを乗せると浮き上がり、テーマ色で縁が光る
private struct OverviewCard<Content: View>: View {
    var index: Int
    var color: Color
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var hovering = false

    var body: some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        LinearGradient(colors: [color.opacity(hovering ? 0.9 : 0.35),
                                                color.opacity(hovering ? 0.35 : 0.05)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: hovering ? 1.5 : 0.75)
                    .allowsHitTesting(false)
            )
            .shadow(color: color.opacity(hovering ? 0.35 : 0), radius: hovering ? 12 : 0, y: hovering ? 4 : 0)
            .scaleEffect(reduceMotion ? 1 : (hovering ? 1.015 : (appeared ? 1 : 0.94)))
            .offset(y: reduceMotion || appeared ? 0 : 14)
            .opacity(appeared ? 1 : 0)
            .onHover { inside in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = inside }
            }
            .onAppear {
                guard !appeared else { return }
                withAnimation(reduceMotion ? nil
                              : .spring(response: 0.55, dampingFraction: 0.78)
                                .delay(Double(index) * 0.045)) {
                    appeared = true
                }
            }
    }
}
