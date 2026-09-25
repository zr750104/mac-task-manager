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

    /// 全コアの tick を 1 秒あけて 2 回読み、その差から使用率を出す。
    static func cpuUsage() -> Double {
        guard let first = ticks() else { return 0 }
        Thread.sleep(forTimeInterval: 1)
        guard let second = ticks() else { return 0 }
        let busy = Double(second.busy &- first.busy)
        let total = Double(second.total &- first.total)
        return total > 0 ? min(1, max(0, busy / total)) : 0
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
        // 更新の頻度はシステムが決める。ここでは「1 分後以降に更新してほしい」と伝えるだけ。
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
            Text(entry.date, style: .time)
                .font(.caption2)
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
