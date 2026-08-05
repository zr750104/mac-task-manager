import Foundation
import Darwin
import IOKit

/// sysctl の薄いラッパ。
enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func integer(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func int32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

/// CPU クラスタ（Apple Silicon の P コア / E コア）。
struct CoreCluster: Sendable, Identifiable {
    let id: Int
    /// "Performance" / "Efficiency"
    let name: String
    let logicalCount: Int
    let physicalCount: Int
    /// host_processor_info の中でこのクラスタが占めるインデックス範囲。
    let range: Range<Int>

    var isPerformance: Bool { name.lowercased().hasPrefix("perf") }
    var displayName: String { isPerformance ? "P コア" : "E コア" }
}

/// 起動時に一度だけ取得する静的なマシン情報。
struct SystemInfo: Sendable {
    let machineModel: String
    let marketingName: String
    let chipName: String
    let physicalCores: Int
    let logicalCores: Int
    let clusters: [CoreCluster]
    let memoryTotal: UInt64
    let gpuName: String
    let gpuCoreCount: Int
    let osVersion: String
    let bootTime: Date
    let pageSize: UInt64
    let hostName: String

    var uptime: TimeInterval { Date().timeIntervalSince(bootTime) }

    var performanceCoreCount: Int {
        clusters.filter(\.isPerformance).reduce(0) { $0 + $1.logicalCount }
    }

    var efficiencyCoreCount: Int {
        clusters.filter { !$0.isPerformance }.reduce(0) { $0 + $1.logicalCount }
    }

    static let current: SystemInfo = .load()

    private static func load() -> SystemInfo {
        let logical = Sysctl.integer("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount
        let physical = Sysctl.integer("hw.physicalcpu") ?? logical

        // Apple Silicon では論理 CPU 番号は「性能の低いクラスタから順」に並ぶ。
        // hw.perflevel0 が最も高性能なので、逆順に並べるとインデックス順と一致する。
        var clusters: [CoreCluster] = []
        let levels = Sysctl.integer("hw.nperflevels") ?? 1
        var cursor = 0
        for level in stride(from: levels - 1, through: 0, by: -1) {
            let logicalCount = Sysctl.integer("hw.perflevel\(level).logicalcpu") ?? logical
            let physicalCount = Sysctl.integer("hw.perflevel\(level).physicalcpu") ?? logicalCount
            let name = Sysctl.string("hw.perflevel\(level).name") ?? (level == 0 ? "Performance" : "Efficiency")
            let end = min(cursor + logicalCount, logical)
            guard end > cursor else { continue }
            clusters.append(CoreCluster(id: level, name: name, logicalCount: logicalCount,
                                        physicalCount: physicalCount, range: cursor..<end))
            cursor = end
        }
        if clusters.isEmpty {
            clusters = [CoreCluster(id: 0, name: "CPU", logicalCount: logical,
                                    physicalCount: physical, range: 0..<logical)]
        }

        let boot: Date = {
            var tv = timeval()
            var size = MemoryLayout<timeval>.size
            guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return Date() }
            return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
        }()

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let gpu = GPUMonitor.staticGPUInfo()

        return SystemInfo(
            machineModel: Sysctl.string("hw.model") ?? "Mac",
            marketingName: marketingModelName() ?? (Sysctl.string("hw.model") ?? "Mac"),
            chipName: Sysctl.string("machdep.cpu.brand_string") ?? "Apple Silicon",
            physicalCores: physical,
            logicalCores: logical,
            clusters: clusters,
            memoryTotal: Sysctl.uint64("hw.memsize") ?? 0,
            gpuName: gpu.name,
            gpuCoreCount: gpu.coreCount,
            osVersion: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            bootTime: boot,
            pageSize: UInt64(Sysctl.integer("hw.pagesize") ?? 16384),
            hostName: ProcessInfo.processInfo.hostName
        )
    }

    /// 「Mac mini (2024)」のような製品名を得る。
    /// デバイスツリーの /product ノードに C 文字列のバイト列として入っている。
    private static func marketingModelName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString,
                                                         kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let name = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            .trimmingCharacters(in: .whitespaces)
        return (name?.isEmpty ?? true) ? nil : name
    }
}
