import Foundation
import Darwin

enum MemoryPressureLevel: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    var label: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "警告"
        case .critical: return "危険"
        }
    }
}

struct MemorySample: Sendable {
    var total: UInt64 = 0
    /// アプリメモリ（Activity Monitor の「App Memory」相当）
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    /// キャッシュされたファイル
    var cachedFiles: UInt64 = 0
    var free: UInt64 = 0
    /// 使用済み = app + wired + compressed
    var used: UInt64 = 0

    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0

    /// メモリプレッシャー 0.0〜1.0（(wired + compressed) / total）
    var pressure: Double = 0
    var pressureLevel: MemoryPressureLevel = .normal

    /// 毎秒のページング回数
    var pageInsPerSec: Double = 0
    var pageOutsPerSec: Double = 0
    var swapInsPerSec: Double = 0
    var swapOutsPerSec: Double = 0
    var faultsPerSec: Double = 0

    var usedRatio: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

final class MemoryMonitor {
    private var previousStats: vm_statistics64?
    private var previousTime: Date?

    func sample() -> MemorySample {
        var result = MemorySample()
        result.total = SystemInfo.current.memoryTotal

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return result }

        let page = SystemInfo.current.pageSize
        func toBytes(_ pages: natural_t) -> UInt64 { UInt64(pages) * page }

        // Activity Monitor と同じ区分けで積算する。
        let purgeable = toBytes(stats.purgeable_count)
        let internalPages = toBytes(stats.internal_page_count)
        let externalPages = toBytes(stats.external_page_count)

        result.wired = toBytes(stats.wire_count)
        result.compressed = toBytes(stats.compressor_page_count)
        result.app = internalPages > purgeable ? internalPages - purgeable : internalPages
        result.cachedFiles = externalPages + purgeable
        result.free = toBytes(stats.free_count)
        result.used = result.app + result.wired + result.compressed

        // ページング統計は累積値なので差分を秒あたりに直す。
        let now = Date()
        if let prev = previousStats, let prevTime = previousTime {
            let dt = now.timeIntervalSince(prevTime)
            if dt > 0 {
                result.pageInsPerSec = Double(stats.pageins &- prev.pageins) / dt
                result.pageOutsPerSec = Double(stats.pageouts &- prev.pageouts) / dt
                result.swapInsPerSec = Double(stats.swapins &- prev.swapins) / dt
                result.swapOutsPerSec = Double(stats.swapouts &- prev.swapouts) / dt
                result.faultsPerSec = Double(stats.faults &- prev.faults) / dt
            }
        }
        previousStats = stats
        previousTime = now

        // スワップ使用量
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            result.swapTotal = swap.xsu_total
            result.swapUsed = swap.xsu_used
        }

        // プレッシャーの数値はカーネルの区分に合わせて算出し、
        // 深刻度のラベルはカーネル自身の判定 (memorystatus) を使う。
        if result.total > 0 {
            result.pressure = min(1, Double(result.wired + result.compressed) / Double(result.total))
        }
        if let raw = Sysctl.int32("kern.memorystatus_vm_pressure_level"),
           let level = MemoryPressureLevel(rawValue: Int(raw)) {
            result.pressureLevel = level
        }
        return result
    }
}
