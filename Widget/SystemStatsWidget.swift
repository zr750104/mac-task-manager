import WidgetKit
import SwiftUI
import Darwin

/// ウィジェット 1 回ぶんの表示内容。
struct StatsEntry: TimelineEntry {
    let date: Date
    /// CPU 使用率（0〜1）
    let cpu: Double
    /// メモリ使用率（0〜1）
    let memory: Double
    let memoryUsed: UInt64
    let memoryTotal: UInt64
}

/// ウィジェットは制限の厳しい環境（App Sandbox）で動くため、
/// その中でも確実に取れる CPU とメモリをウィジェット自身が計測する。
enum StatsSampler {

    static func sample() -> StatsEntry {
        let cpu = cpuUsage()
        let (used, total) = memoryUsage()
        return StatsEntry(date: .now, cpu: cpu,
                          memory: total > 0 ? Double(used) / Double(total) : 0,
                          memoryUsed: used, memoryTotal: total)
    }

    /// 前回の更新時に保存しておいた tick との差から、その間の平均使用率を出す。
    /// アプリ本体が数秒おきに更新を依頼するので、待たずに「直近数秒の平均」が得られる。
    /// 前回の値が無い・古すぎる（2 分超）ときだけ、0.5 秒あけて 2 回読む。
    static func cpuUsage() -> Double {
        guard let now = ticks() else { return 0 }
        let store = UserDefaults.standard
        defer {
            store.set(Double(now.busy), forKey: "lastBusyTicks")
            store.set(Double(now.total), forKey: "lastTotalTicks")
            store.set(Date().timeIntervalSince1970, forKey: "lastTicksTime")
        }
        let lastTime = store.double(forKey: "lastTicksTime")
        let lastBusy = UInt64(store.double(forKey: "lastBusyTicks"))
        let lastTotal = UInt64(store.double(forKey: "lastTotalTicks"))
        let age = Date().timeIntervalSince1970 - lastTime

        if lastTime > 0, age < 120, now.total > lastTotal, now.busy >= lastBusy {
            return ratio(busy: now.busy - lastBusy, total: now.total - lastTotal)
        }
        Thread.sleep(forTimeInterval: 0.5)
        guard let second = ticks() else { return 0 }
        return ratio(busy: second.busy &- now.busy, total: second.total &- now.total)
    }

    private static func ratio(busy: UInt64, total: UInt64) -> Double {
        total > 0 ? min(1, max(0, Double(busy) / Double(total))) : 0
    }

    private static func ticks() -> (busy: UInt64, total: UInt64)? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var busy: UInt64 = 0, total: UInt64 = 0
        for core in 0..<Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return (busy, total)
    }

    /// アクティビティモニタと同じく「アプリメモリ + 確保済み + 圧縮」を使用中とみなす。
    static func memoryUsage() -> (used: UInt64, total: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }
}

struct StatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatsEntry {
        StatsEntry(date: .now, cpu: 0.25, memory: 0.6,
                   memoryUsed: 10 << 30, memoryTotal: 16 << 30)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatsEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : StatsSampler.sample())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatsEntry>) -> Void) {
        // 普段はアプリ本体が数秒おきに更新を依頼する（WidgetRefresher）。
        // アプリが起動していないときの保険として「1 分後以降に更新してほしい」とも伝えておく
        // （この場合はシステムが決めた 1〜15 分後のどこかで更新される）。
        let entry = StatsSampler.sample()
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(60))))
    }
}

struct StatsWidgetView: View {
    let entry: StatsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("タスクマネージャー")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            gauge("CPU", entry.cpu, .blue)
            gauge("メモリ", entry.memory, .purple)
            Spacer(minLength: 0)
            // アプリが数秒おきに更新するので、何時何分何秒の値かを出す。
            Text(entry.date, format: .dateTime.hour().minute().second())
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func gauge(_ title: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption.weight(.medium))
                Spacer()
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            ProgressView(value: value).tint(color)
        }
    }
}

struct SystemStatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SystemStats", provider: StatsProvider()) { entry in
            StatsWidgetView(entry: entry)
        }
        .configurationDisplayName("システム状況")
        .description("CPU とメモリの使用率を表示します。")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct TaskManagerWidgets: WidgetBundle {
    var body: some Widget {
        SystemStatsWidget()
    }
}
