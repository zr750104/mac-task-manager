import SwiftUI

enum Panel: String, CaseIterable, Identifiable, Hashable {
    case overview, cpu, memory, gpu, npu, temperature, disk, network, processes, startup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概要"
        case .cpu: return "CPU"
        case .memory: return "メモリ"
        case .gpu: return "GPU"
        case .npu: return "NPU"
        case .temperature: return "温度・電力"
        case .disk: return "ディスク"
        case .network: return "ネットワーク"
        case .processes: return "プロセス"
        case .startup: return "起動項目"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .gpu: return "cube.transparent"
        case .npu: return "brain"
        case .temperature: return "thermometer.medium"
        case .disk: return "internaldrive"
        case .network: return "network"
        case .processes: return "list.bullet.rectangle"
        case .startup: return "power"
        }
    }

    var color: Color {
        switch self {
        case .overview: return .secondary
        case .cpu: return Palette.cpu
        case .memory: return Palette.memory
        case .gpu: return Palette.gpu
        case .npu: return Palette.efficiencyCore
        case .temperature: return Palette.temperature
        case .disk: return Palette.disk
        case .network: return Palette.network
        case .processes: return .secondary
        case .startup: return .secondary
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var engine: MetricsEngine
    @EnvironmentObject private var settings: AppSettings

    /// 実体は AppSettings 側。スクリーンショット書き出しから切り替えるため外に出してある。
    private var selection: Panel { settings.selection }
    private var selectionBinding: Binding<Panel> {
        Binding(get: { settings.selection }, set: { settings.selection = $0 })
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: selectionBinding)
                .navigationSplitViewColumnWidth(min: 150, ideal: 216, max: 280)
        } detail: {
            VStack(spacing: 10) {
                UpdateBanner()
                content
            }
            // 概要は画面いっぱいに敷き詰めてスクロールを避けるため余白を詰める。
            .padding(selection == .overview ? 12 : 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(selection.title)
        .toolbar {
            ToolbarItem(placement: .status) {
                StatusToolbar()
            }
        }
        .onChange(of: settings.selection) { _, new in
            // プロセス一覧の収集はコストが高いので、必要な画面でだけ動かす。
            engine.isProcessTabVisible = (new == .processes)
            engine.isStartupTabVisible = (new == .startup)
            engine.isOverviewVisible = (new == .overview)
            if new == .processes {
                Task { await engine.refreshProcessesNow() }
            }
        }
        .onAppear {
            engine.isProcessTabVisible = (selection == .processes)
            engine.isStartupTabVisible = (selection == .startup)
            engine.isOverviewVisible = (selection == .overview)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .overview: OverviewPanel(selection: selectionBinding)
        case .cpu: CPUPanel()
        case .memory: MemoryPanel()
        case .gpu: GPUPanel()
        case .npu: NPUPanel()
        case .temperature: TemperaturePanel()
        case .disk: DiskPanel()
        case .network: NetworkPanel()
        case .processes: ProcessPanel()
        case .startup: StartupPanel()
        }
    }
}

/// ツールバー右側の更新間隔ピッカーと稼働時間。
private struct StatusToolbar: View {
    @EnvironmentObject private var engine: MetricsEngine
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            if engine.thermalState != .nominal {
                Label(engine.thermalState.label, systemImage: "thermometer.medium")
                    .font(.caption)
                    .foregroundStyle(engine.thermalState == .critical ? .red : .orange)
            }
            Text("稼働 \(Fmt.duration(engine.info.uptime))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            UpdateStatusView()
            Picker("更新間隔", selection: $engine.refreshRate) {
                ForEach(RefreshRate.allCases) { rate in
                    Text(rate.shortLabel).tag(rate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
        }
        .onReceive(ticker) { now = $0 }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var engine: MetricsEngine
    @Binding var selection: Panel

    var body: some View {
        List(selection: $selection) {
            Section("モニター") {
                ForEach(Panel.allCases) { panel in
                    SidebarRow(panel: panel).tag(panel)
                }
            }
            // ウィンドウを小さくしたときに項目と重ならないよう、
            // 固定表示ではなくリストの一部としてスクロールさせる。
            Section {
                MachineSummary()
            }
        }
        .listStyle(.sidebar)
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var engine: MetricsEngine
    var panel: Panel

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: panel.icon)
                .frame(width: 18)
                .foregroundStyle(panel.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(panel.title).font(.callout)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            chart
        }
        .padding(.vertical, 3)
    }

    private var detail: String? {
        let snapshot = engine.snapshot
        switch panel {
        case .overview: return nil
        case .cpu: return Fmt.percent(snapshot.cpu.total, decimals: 0)
        case .memory:
            return "\(Fmt.bytes(snapshot.memory.used)) / \(Fmt.bytes(snapshot.memory.total))"
        case .gpu: return snapshot.gpu.available ? Fmt.percent(snapshot.gpu.utilization, decimals: 0) : "—"
        case .npu: return Fmt.percent(snapshot.neuralEngine.utilization, decimals: 0)
        case .temperature:
            return engine.temperature.available
                ? String(format: "%.1f ℃", engine.temperature.socMax) : "—"
        case .disk: return "R \(Fmt.rate(snapshot.disk.readRate))"
        case .network: return "↓ \(Fmt.rate(snapshot.network.downloadRate))"
        case .processes: return "\(engine.processes.isEmpty ? "—" : Fmt.count(engine.processes.count)) 個"
        case .startup: return engine.startup.items.isEmpty ? "—" : "\(engine.startup.items.count) 個"
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch panel {
        case .cpu:
            MiniChart(values: engine.cpuHistory.padded, maxValue: 1, color: Palette.cpu)
        case .memory:
            MiniChart(values: engine.memoryHistory.padded, maxValue: 1, color: Palette.memory)
        case .gpu:
            MiniChart(values: engine.gpuHistory.padded, maxValue: 1, color: Palette.gpu)
        case .npu:
            MiniChart(values: engine.neuralEngineUtilizationHistory.padded, maxValue: 1,
                      color: Palette.efficiencyCore)
        case .temperature:
            MiniChart(values: engine.temperatureHistory.padded, maxValue: 110,
                      color: Palette.heat(engine.temperature.socMax))
        case .disk:
            MiniChart(values: engine.diskReadHistory.padded, maxValue: nil, color: Palette.disk)
        case .network:
            MiniChart(values: engine.networkDownHistory.padded, maxValue: nil, color: Palette.network)
        default:
            EmptyView()
        }
    }
}

/// サイドバー下部のマシン情報。
private struct MachineSummary: View {
    @EnvironmentObject private var engine: MetricsEngine

    var body: some View {
        let info = engine.info
        VStack(alignment: .leading, spacing: 2) {
            Divider().padding(.bottom, 4)
            Text(info.marketingName)
                .font(.caption.weight(.semibold))
            Text("\(info.chipName) · \(info.logicalCores) コア")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("P \(info.performanceCoreCount) / E \(info.efficiencyCoreCount) · GPU \(info.gpuCoreCount) コア")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(Fmt.bytes(info.memoryTotal)) · \(info.osVersion)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}
