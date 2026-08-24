import Foundation
import AppKit
import Combine

struct Snapshot: Sendable {
    var cpu = CPUSample()
    var memory = MemorySample()
    var gpu = GPUSample()
    var network = NetworkSample()
    var disk = DiskSample()
    var power = PowerSample()
    var neuralEngine = NeuralEngineSample()
    var timestamp = Date()
}

/// 計測処理をメインスレッドから切り離すためのアクター。
actor Sampler {
    private let cpu = CPUMonitor()
    private let memory = MemoryMonitor()
    private let gpu = GPUMonitor()
    private let network = NetworkMonitor()
    private let disk = DiskMonitor()
    private let processes = ProcessMonitor()
    private let temperature = TemperatureMonitor()
    private let power = PowerMonitor()
    private let neuralEngine = NeuralEngineMonitor()
    private let battery = BatteryMonitor()
    private let startup = StartupMonitor()

    func collectStartup() -> StartupSample {
        startup.sample()
    }

    func collectTemperature() -> TemperatureSample {
        temperature.sample()
    }

    func collectBattery() -> BatterySample {
        battery.sample()
    }

    func collect() -> Snapshot {
        let powerSample = power.sample()
        return Snapshot(cpu: cpu.sample(),
                        memory: memory.sample(),
                        gpu: gpu.sample(),
                        network: network.sample(),
                        disk: disk.sample(),
                        power: powerSample,
                        neuralEngine: neuralEngine.sample(watts: powerSample.neuralEngine),
                        timestamp: Date())
    }

    func collectProcesses() -> [ProcessRow] {
        processes.sample()
    }
}

enum RefreshRate: Double, CaseIterable, Identifiable, Sendable {
    case fast = 0.5
    case normal = 1
    case slow = 2
    case verySlow = 5

    var id: Double { rawValue }
    var label: String {
        switch self {
        case .fast: return "0.5 秒（高頻度）"
        case .normal: return "1 秒（標準）"
        case .slow: return "2 秒（低負荷）"
        case .verySlow: return "5 秒（最小）"
        }
    }
    var shortLabel: String {
        switch self {
        case .fast: return "0.5s"
        case .normal: return "1s"
        case .slow: return "2s"
        case .verySlow: return "5s"
        }
    }
}

@MainActor
final class MetricsEngine: ObservableObject {
    /// ウインドウとメニューバー常駐で同じ計測結果を共有するための単一インスタンス。
    static let shared = MetricsEngine()

    static let historyLength = 120

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var processes: [ProcessRow] = []
    @Published private(set) var temperature = TemperatureSample()
    @Published private(set) var battery = BatterySample()
    @Published private(set) var startup = StartupSample()
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal

    // グラフ用の時系列
    @Published private(set) var cpuHistory = History(capacity: historyLength)
    @Published private(set) var cpuClusterHistory: [History] = []
    @Published private(set) var coreHistories: [History] = []
    @Published private(set) var gpuHistory = History(capacity: historyLength)
    @Published private(set) var memoryHistory = History(capacity: historyLength)
    @Published private(set) var pressureHistory = History(capacity: historyLength)
    @Published private(set) var networkDownHistory = History(capacity: historyLength)
    @Published private(set) var networkUpHistory = History(capacity: historyLength)
    @Published private(set) var diskReadHistory = History(capacity: historyLength)
    @Published private(set) var diskWriteHistory = History(capacity: historyLength)
    @Published private(set) var temperatureHistory = History(capacity: historyLength)
    /// CPU + GPU の消費電力（W）
    @Published private(set) var powerHistory = History(capacity: historyLength)
    /// Neural Engine の消費電力（W）
    @Published private(set) var neuralEngineHistory = History(capacity: historyLength)
    /// Neural Engine の使用率（0〜1）
    @Published private(set) var neuralEngineUtilizationHistory = History(capacity: historyLength)

    /// 更新間隔は AppSettings が保持する。
    /// ここで @Published にすると毎秒の計測更新でメニューが作り直されてしまう。
    var refreshRate: RefreshRate { AppSettings.shared.refreshRate }

    /// 設定側で間隔が変わったら呼ばれる。
    func refreshRateDidChange() { restartTimer() }

    /// プロセス一覧はコストが高いので、表示中のときだけ更新する。
    @Published var isProcessTabVisible = false
    /// 起動項目も plist の走査が必要なので、表示中のときだけ更新する。
    @Published var isStartupTabVisible = false
    /// 概要画面では上位プロセスだけ使うので、粗い間隔で収集する。
    @Published var isOverviewVisible = false

    let info = SystemInfo.current
    private let sampler = Sampler()
    private var timerTask: Task<Void, Never>?
    private var lastProcessUpdate = Date.distantPast
    private var lastTemperatureUpdate = Date.distantPast
    private var lastStartupUpdate = Date.distantPast
    private var isSampling = false

    init() {
        cpuClusterHistory = info.clusters.map { _ in History(capacity: Self.historyLength) }
        coreHistories = (0..<info.logicalCores).map { _ in History(capacity: Self.historyLength) }
        start()
    }

    deinit {
        timerTask?.cancel()
    }

    func start() {
        restartTimer()
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func restartTimer() {
        timerTask?.cancel()
        let interval = refreshRate.rawValue
        timerTask = Task { [weak self] in
            // 起動直後に 1 回目を取り、以後は一定間隔で更新する。
            await self?.tick()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                await self?.tick()
            }
        }
    }

    private func tick() async {
        guard !isSampling else { return }
        isSampling = true
        defer { isSampling = false }

        let new = await sampler.collect()
        apply(new)

        // 温度は 40 個ほどのセンサーを 1 個ずつ読むため 1 回 50ms ほどかかる。
        // 温度自体ゆっくりしか変化しないので最短 2 秒間隔に間引く。
        // バッテリーも同様に変化が遅いのでまとめて更新する。
        let temperatureInterval = max(2.0, refreshRate.rawValue)
        if Date().timeIntervalSince(lastTemperatureUpdate) >= temperatureInterval {
            lastTemperatureUpdate = Date()
            temperature = await sampler.collectTemperature()
            battery = await sampler.collectBattery()
        }
        // グラフの時間軸を他と揃えるため、更新の有無にかかわらず毎回積む。
        if temperature.available {
            temperatureHistory.append(temperature.socMax)
        }

        // 起動項目は滅多に変わらないので、表示中に 5 秒間隔で十分。
        if isStartupTabVisible, Date().timeIntervalSince(lastStartupUpdate) >= 5 {
            lastStartupUpdate = Date()
            startup = await sampler.collectStartup()
        }

        // プロセス一覧は最短でも 2 秒間隔に間引く。
        // 概要画面でも上位プロセスを出すが、あちらは一覧を出さないので 5 秒で十分。
        let processInterval = isProcessTabVisible ? max(2.0, refreshRate.rawValue) : 5.0
        if isProcessTabVisible || isOverviewVisible,
           Date().timeIntervalSince(lastProcessUpdate) >= processInterval {
            lastProcessUpdate = Date()
            let rows = await sampler.collectProcesses()
            processes = decorate(rows)
        }
    }

    private func apply(_ new: Snapshot) {
        snapshot = new
        thermalState = ProcessInfo.processInfo.thermalState

        cpuHistory.append(new.cpu.total)
        for index in cpuClusterHistory.indices where index < new.cpu.perCluster.count {
            cpuClusterHistory[index].append(new.cpu.perCluster[index])
        }
        for index in coreHistories.indices where index < new.cpu.perCore.count {
            coreHistories[index].append(new.cpu.perCore[index])
        }
        gpuHistory.append(new.gpu.utilization)
        memoryHistory.append(new.memory.usedRatio)
        pressureHistory.append(new.memory.pressure)
        networkDownHistory.append(new.network.downloadRate)
        networkUpHistory.append(new.network.uploadRate)
        diskReadHistory.append(new.disk.readRate)
        diskWriteHistory.append(new.disk.writeRate)
        if new.power.available {
            powerHistory.append(new.power.cpu + new.power.gpu)
        }
        neuralEngineHistory.append(new.neuralEngine.watts)
        neuralEngineUtilizationHistory.append(new.neuralEngine.utilization)
    }

    /// 概要画面に出す上位プロセス。
    func topProcesses(by keyPath: KeyPath<ProcessRow, Double>, limit: Int = 3) -> [ProcessRow] {
        Array(processes.sorted { $0[keyPath: keyPath] > $1[keyPath: keyPath] }.prefix(limit))
    }

    func topProcessesByMemory(limit: Int = 3) -> [ProcessRow] {
        Array(processes.sorted { $0.memory > $1.memory }.prefix(limit))
    }

    /// GUI アプリはローカライズされた名前とバンドル ID を持つので、そちらを優先表示する。
    private func decorate(_ rows: [ProcessRow]) -> [ProcessRow] {
        var apps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            apps[app.processIdentifier] = app
        }
        return rows.map { row in
            var row = row
            if let app = apps[row.pid] {
                if let name = app.localizedName, !name.isEmpty { row.name = name }
                row.bundleIdentifier = app.bundleIdentifier
                row.isGUIApp = app.activationPolicy == .regular
            }
            return row
        }
    }

    /// プロセスを終了し、結果メッセージを返す（成功時は nil）。
    func terminate(pid: pid_t, name: String, force: Bool) -> String? {
        switch ProcessMonitor.terminate(pid: pid, force: force) {
        case .success:
            processes.removeAll { $0.pid == pid }
            return nil
        case .permissionDenied:
            return "「\(name)」(PID \(pid)) を終了する権限がありません。別のユーザーまたはシステムが所有するプロセスです。"
        case .notFound:
            processes.removeAll { $0.pid == pid }
            return nil
        case .failed(let code):
            return "「\(name)」(PID \(pid)) の終了に失敗しました（errno \(code)）。"
        }
    }

    /// 即時に起動項目を取り直す。
    func refreshStartupNow() async {
        lastStartupUpdate = Date()
        startup = await sampler.collectStartup()
    }

    /// 即時にプロセス一覧を取り直す。
    func refreshProcessesNow() async {
        lastProcessUpdate = Date()
        let rows = await sampler.collectProcesses()
        processes = decorate(rows)
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "正常"
        case .fair: return "やや上昇"
        case .serious: return "高温"
        case .critical: return "危険"
        @unknown default: return "不明"
        }
    }
}
