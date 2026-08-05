import Foundation
import Darwin

struct CPUSample: Sendable {
    /// 全体使用率 0.0〜1.0
    var total: Double = 0
    var user: Double = 0
    var system: Double = 0
    var idle: Double = 1
    var nice: Double = 0
    /// 論理コアごとの使用率 0.0〜1.0（index は host_processor_info の並び）
    var perCore: [Double] = []
    /// クラスタ（P/E）ごとの平均使用率
    var perCluster: [Double] = []
    var loadAverage: [Double] = [0, 0, 0]
    var threadCount: Int = 0
    var processCount: Int = 0
    /// 起動からの総コンテキストスイッチ数などは取れないため、割り込み系は省略。
}

/// host_processor_info の tick 差分から CPU 使用率を求める。
final class CPUMonitor {
    private var previous: [[UInt32]] = []

    func sample() -> CPUSample {
        var result = CPUSample()

        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let status = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount, &infoArray, &infoCount)
        guard status == KERN_SUCCESS, let info = infoArray else { return result }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        let states = Int(CPU_STATE_MAX)
        var current: [[UInt32]] = []
        current.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = states * core
            current.append([
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ])
        }

        defer { previous = current }
        guard previous.count == current.count else {
            result.perCore = Array(repeating: 0, count: current.count)
            result.perCluster = Array(repeating: 0, count: SystemInfo.current.clusters.count)
            result.loadAverage = Self.loadAverage()
            return result
        }

        var totals = [Double](repeating: 0, count: 4)
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)

        for core in 0..<current.count {
            // tick カウンタは UInt32 で巻き戻るため &- で差分を取る。
            let deltas = (0..<4).map { Double(current[core][$0] &- previous[core][$0]) }
            for i in 0..<4 { totals[i] += deltas[i] }
            let busy = deltas[0] + deltas[1] + deltas[3]
            let all = busy + deltas[2]
            perCore.append(all > 0 ? min(1, busy / all) : 0)
        }

        result.perCore = perCore
        let grandTotal = totals.reduce(0, +)
        if grandTotal > 0 {
            result.user = totals[0] / grandTotal
            result.system = totals[1] / grandTotal
            result.idle = totals[2] / grandTotal
            result.nice = totals[3] / grandTotal
            result.total = min(1, 1 - result.idle)
        }

        result.perCluster = SystemInfo.current.clusters.map { cluster in
            let slice = perCore.indices.filter { cluster.range.contains($0) }.map { perCore[$0] }
            guard !slice.isEmpty else { return 0 }
            return slice.reduce(0, +) / Double(slice.count)
        }
        result.loadAverage = Self.loadAverage()
        return result
    }

    static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return [0, 0, 0] }
        return loads
    }
}
