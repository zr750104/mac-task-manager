import SwiftUI

/// 概要の見せ方。グラフ（推移）か、車のメーター風（現在値）か。
enum OverviewStyle: String, CaseIterable, Identifiable {
    case chart, meter
    var id: String { rawValue }
    /// 保存先の UserDefaults のキー（画面書き出しからも使う）
    static let storageKey = "overviewStyle"
}

struct OverviewPanel: View {
    @EnvironmentObject private var engine: MetricsEngine
    @Binding var selection: Panel
    /// 毎秒変わるものではないので AppSettings ではなくここで保存する。
    @AppStorage(OverviewStyle.storageKey) private var style: OverviewStyle = .chart

    /// メーター表示のときの目盛り。
    private struct GaugeSpec {
        var ratio: Double
        var redline: Double = 0.85
        var available = true
        /// 目盛りの数字の区切り数（0〜10 なら 10）
        var intervals = 10
        /// 文字盤の倍率表示（例：「×10 %」）
        var multiplier: String? = "×10 %"
    }

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
        /// メーター表示の中身。nil のカードはメーター表示でもグラフ側の中身を使う。
        var gauge: GaugeSpec? = nil
        /// メーター表示でカード全体を差し替えたいときの中身（プロセスなど）
        var meterContent: AnyView? = nil
        /// 最後の行が埋まらないとき、空いた枠まで横に広げる（最後のカードだけが対象）
        var expandsToFill = false
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
                // 最後の行が埋まらないとき、最後のカード（デバイスのバッテリー）を空いた枠まで広げる。
                // LazyVGrid では 1 枚だけ複数の列にまたがらせられないので、行ごとに並べている。
                let cellWidth = max(0, (geometry.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
                let numbered = Array(cards.enumerated())
                let grid = VStack(alignment: .leading, spacing: spacing) {
                    ForEach(0..<rows, id: \.self) { row in
                        let rowCards = Array(numbered[(row * columns)..<min((row + 1) * columns, numbered.count)])
                        HStack(spacing: spacing) {
                            ForEach(rowCards, id: \.element.id) { index, card in
                                let span = index == cards.count - 1 && card.expandsToFill
                                    ? columns - (rowCards.count - 1) : 1
                                OverviewCard(index: index, color: card.color) {
                                    cardView(card, index: index, height: cardHeight)
                                }
                                .frame(width: cellWidth * CGFloat(span) + spacing * CGFloat(span - 1))
                            }
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

    /// 列数。カードは 11 枚（ノート型は Mac 自身のバッテリーを加えて 12 枚）。
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
                                         color: Palette.cpu, gridRows: 2, gridColumns: 4)),
            gauge: GaugeSpec(ratio: cpu.total)))

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
                                         color: Palette.memory, gridRows: 2, gridColumns: 4)),
            gauge: GaugeSpec(ratio: memory.usedRatio)))

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
                                         color: Palette.gpu, gridRows: 2, gridColumns: 4)),
            gauge: GaugeSpec(ratio: gpu.utilization, available: gpu.available)))

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
                                         gridRows: 2, gridColumns: 4)),
            gauge: GaugeSpec(ratio: temperature.socMax / Self.temperatureCeiling,
                             redline: 95 / Self.temperatureCeiling,
                             available: temperature.available,
                             intervals: 11, multiplier: "×10 ℃")))

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
                                         color: Palette.gpu, gridRows: 2, gridColumns: 4)),
            gauge: wattGauge(power.cpu + power.gpu, history: engine.powerHistory.padded,
                             available: power.available)))

        // Neural Engine（NPU）
        let ane = snapshot.neuralEngine
        list.append(Card(
            panel: .npu, title: "NPU (Neural Engine)", icon: "brain", color: Palette.efficiencyCore,
            value: ane.available ? Fmt.percent(ane.utilization) : "—",
            details: [("状態", ane.stateLabel),
                      ("消費電力", String(format: "%.2fW", ane.watts)),
                      ("推論/秒", Fmt.count(Int(ane.operationsPerSecond)))],
            caption: "推論 \(Fmt.count(Int(ane.referenceRate))) 回/秒を 100% とした比率 · GPU 使用率とは別物です",
            content: AnyView(MetricChart(values: engine.neuralEngineUtilizationHistory.padded,
                                         maxValue: 1, color: Palette.efficiencyCore,
                                         gridRows: 2, gridColumns: 4)),
            gauge: GaugeSpec(ratio: ane.utilization, available: ane.available)))

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
                                             secondaryColor: Palette.upload, maxValue: nil)),
            gauge: rateGauge(disk.readRate + disk.writeRate,
                             history: Self.sum(engine.diskReadHistory.padded,
                                               engine.diskWriteHistory.padded),
                             floor: 1024 * 1024)))

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
                                             secondaryColor: Palette.upload, maxValue: nil)),
            gauge: rateGauge(network.downloadRate + network.uploadRate,
                             history: Self.sum(engine.networkDownHistory.padded,
                                               engine.networkUpHistory.padded),
                             floor: 1024 * 1024)))

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
            content: AnyView(processList(top)),
            meterContent: AnyView(processGauges(top))))

        // ストレージ容量
        list.append(Card(
            panel: .disk, title: "ストレージ", icon: "externaldrive", color: Palette.disk,
            value: storageValue,
            details: [],
            caption: "ボリューム \(disk.volumes.count) 個 · 物理ディスク \(disk.disks.count) 台",
            content: AnyView(volumeList(disk.volumes)),
            gauge: disk.volumes.first.map {
                GaugeSpec(ratio: $0.usedRatio, redline: 0.9)
            }))

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

        // つないでいる機器のバッテリー（iPhone・iPad・AirPods など）。
        // 最後の行の空いた枠まで広げるので、常に最後のカードにする。
        // クリックすると、Mac 本体のバッテリーもある「温度・電力」画面へ移る。
        let devices = engine.devices
        let liveCount = devices.filter { !$0.isStale }.count
        list.append(Card(
            panel: .temperature, title: "デバイスのバッテリー", icon: "battery.75percent",
            color: Palette.disk,
            // 台数は今つながっている機器だけ数える（「前回の値」の機器は含めない）。
            value: devices.isEmpty ? "—" : "接続 \(liveCount) 台",
            details: [],
            caption: devices.isEmpty
                ? "iPhone・iPad（USB / Wi-Fi）や Apple Watch、AirPods などを表示します"
                : "iPhone・iPad・Apple Watch と Bluetooth 機器 · 30 秒ごと（Apple Watch は 3 分ごと）に更新",
            content: AnyView(deviceList(devices)),
            meterContent: AnyView(deviceGauges(devices)),
            expandsToFill: true))

        return list
    }

    /// 温度メーターの上限（℃）。Apple Silicon はおおむね 100℃ 付近で性能を落とす。
    private static let temperatureCeiling = 110.0

    /// 消費電力のメーター。直近 2 分の最大値から目盛りを決める（下限 10 W）。
    private func wattGauge(_ value: Double, history: [Double], available: Bool) -> GaugeSpec {
        let ceiling = max(10, ChartScale.ceiling(maxValue: nil, values: history + [value]))
        return GaugeSpec(ratio: value / ceiling, available: available,
                         multiplier: "×" + Self.trimmed(ceiling / 10) + " W")
    }

    /// 転送速度のメーター。直近 2 分の最大値から目盛りを決める。
    /// 表示の数値と同じ 1024 進の単位で切りのいい上限にし、文字盤の倍率と数値が食い違わないようにする。
    /// 待機中のわずかな変動で針が暴れないよう、上限には下限を設けている。
    private func rateGauge(_ value: Double, history: [Double], floor: Double) -> GaugeSpec {
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        let peak = max(floor, (history + [value]).max() ?? 0)
        var unit = 0
        var unitSize = 1.0
        while peak / unitSize >= 1024, unit < units.count - 1 {
            unitSize *= 1024
            unit += 1
        }
        let ceilingInUnit = ChartScale.ceiling(maxValue: nil, values: [peak / unitSize])
        return GaugeSpec(ratio: value / (ceilingInUnit * unitSize),
                         multiplier: "×" + Self.trimmed(ceilingInUnit / 10) + " " + units[unit])
    }

    /// 0.5 → "0.5"、10 → "10" のように余計な 0 を付けない。
    private static func trimmed(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%g", value)
    }

    /// カードの値は読み＋書き（受信＋送信）の合計なので、目盛りも合計の履歴から決める。
    private static func sum(_ a: [Double], _ b: [Double]) -> [Double] {
        zip(a, b).map { $0 + $1 }
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

    /// 上位 4 件を小さなメーターで並べる。順位で識別して、入れ替わってもメーターを作り直さない。
    private func processGauges(_ rows: [ProcessRow]) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { rank in
                let row = rank < rows.count ? rows[rank] : nil
                VStack(spacing: 1) {
                    // プロセスの CPU 使用率は 1 コアぶんを 100% とする（複数コアで 100% を超える）。
                    MetricGauge(ratio: (row?.cpuPercent ?? 0) / 100, color: Palette.cpu,
                                available: row != nil, compact: true,
                                ignitionDelay: Double(rank) * 0.06)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(row.map { Fmt.cpuPercent($0.cpuPercent) } ?? "—")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                    HStack(spacing: 2) {
                        if let row {
                            AppIconView(bundlePath: row.appBundlePath, isApp: row.isGUIApp, size: 10)
                        }
                        Text(row?.name ?? " ")
                            .font(.system(size: 8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private static func deviceColor(_ level: Double) -> Color {
        // メーターのレッドゾーン（20% 以下）と揃える。
        level <= 0.2 ? .red : (level < 0.5 ? Palette.gpu : Palette.disk)
    }

    /// 機器ごとの残量。読める機器が無いときは案内を出す。
    private func deviceList(_ devices: [DeviceBattery]) -> some View {
        // カードの高さに入る行数だけ出す（1 行はおよそ 22pt）。全体の台数はカード右上に出ている。
        GeometryReader { geometry in
            let rowHeight: CGFloat = 22
            let fits = max(1, Int((geometry.size.height + 3) / rowHeight))
            let shown = min(devices.count, fits)
            let showsMore = devices.count > shown
                && CGFloat(shown) * rowHeight + 12 <= geometry.size.height
            deviceRows(devices, shown: shown, showsMore: showsMore)
        }
    }

    private func deviceRows(_ devices: [DeviceBattery], shown: Int, showsMore: Bool) -> some View {
        VStack(spacing: 3) {
            if devices.isEmpty {
                Spacer(minLength: 0)
                Text("iPhone や iPad を USB でつなぐか、Finder で「Wi-Fi 接続時にこのデバイスを表示」を有効にすると残量が表示されます")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else {
                // 並びは今の値が先。入りきらない分は件数だけ出す。
                ForEach(devices.prefix(shown)) { device in
                    VStack(spacing: 1) {
                        HStack(spacing: 5) {
                            Image(systemName: device.kind.symbol)
                                .font(.caption2)
                                .frame(width: 13)
                                .foregroundStyle(.secondary)
                            Text(device.name)
                                .font(.caption2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(1)
                            Text(device.subtitle)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            if device.isCharging {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.yellow)
                            }
                            Text(Fmt.percent(device.level, decimals: 0))
                                .font(.caption2.weight(.medium))
                                .monospacedDigit()
                                .fixedSize()
                        }
                        UsageBar(ratio: device.level, color: Self.deviceColor(device.level), height: 4)
                    }
                    // 古い値（未接続の機器の前回の値）は薄く出す。
                    .opacity(device.isStale ? 0.5 : 1)
                }
                if showsMore {
                    Text("ほか \(devices.count - shown) 台")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// メーター表示。残量は少ないほど危ないので、0〜20% をレッドゾーンにする。
    /// 枠は位置で識別し、機器が増減してもメーターを作り直さない。
    /// 枠は 4 つを基本に、台数に合わせて最大 6 つまで増やす。それより多い分は件数だけ出す。
    private func deviceGauges(_ devices: [DeviceBattery]) -> some View {
        let slots = min(6, max(4, devices.count))
        return VStack(spacing: 1) {
        HStack(spacing: 4) {
            ForEach(0..<slots, id: \.self) { slot in
                let device = slot < devices.count ? devices[slot] : nil
                VStack(spacing: 1) {
                    MetricGauge(ratio: device?.level ?? 0, color: Palette.disk, redline: 0.2,
                                lowZone: true, available: device != nil, compact: true,
                                ignitionDelay: Double(slot) * 0.06)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 2) {
                        if device?.isCharging == true {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.yellow)
                        }
                        Text(device.map { Fmt.percent($0.level, decimals: 0) } ?? "—")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .lineLimit(1)
                    HStack(spacing: 2) {
                        if let device {
                            Image(systemName: device.kind.symbol)
                                .font(.system(size: 8))
                        }
                        Text(device?.name ?? " ")
                            .font(.system(size: 8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity)
                    // どの機器か分かるよう、機種名も添える（無ければ接続の種類）。
                    Text(device.map { $0.isStale ? "前回の値" : ($0.model ?? $0.connection) } ?? " ")
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity)
                .opacity(device?.isStale == true ? 0.5 : 1)
            }
        }
        if devices.count > slots {
            Text("ほか \(devices.count - slots) 台")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
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
            Picker("表示", selection: $style) {
                Image(systemName: "chart.xyaxis.line")
                    .help("グラフ表示")
                    .tag(OverviewStyle.chart)
                Image(systemName: "gauge.with.needle")
                    .help("メーター表示")
                    .tag(OverviewStyle.meter)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("グラフ表示とメーター表示を切り替えます")
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

    private func cardView(_ card: Card, index: Int, height: CGFloat) -> some View {
        // 高さに応じて出す情報を切り替える。狭いときは値とグラフだけにする。
        let showsDetails = height >= 150 && !card.details.isEmpty
        let showsCaption = height >= 118
        let meter = style == .meter
        let gauge = meter ? card.gauge : nil

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
                    // メーター表示では数値をメーターの横に大きく出す。
                    if gauge == nil {
                        Text(card.value)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }

                Group {
                    if let gauge {
                        meterBody(card, gauge: gauge, index: index)
                    } else if meter, let meterContent = card.meterContent {
                        meterContent
                    } else {
                        card.content
                    }
                }
                .frame(maxHeight: .infinity)

                // メーター表示では内訳をメーターの横に並べるので、下の段には出さない。
                if showsDetails && gauge == nil {
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

extension OverviewPanel {
    /// メーター表示のカードの中身。左にメーター、右に大きな数値と内訳を並べる。
    private func meterBody(_ card: Card, gauge: GaugeSpec, index: Int) -> some View {
        HStack(spacing: 12) {
            MetricGauge(ratio: gauge.ratio, color: card.color, redline: gauge.redline,
                        available: gauge.available, intervals: gauge.intervals,
                        multiplier: gauge.multiplier, ignitionDelay: Double(index) * 0.045)
                .aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                ForEach(Array(card.details.enumerated()), id: \.offset) { _, detail in
                    HStack(spacing: 6) {
                        Text(detail.0)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(detail.1)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .font(.system(size: 10))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
