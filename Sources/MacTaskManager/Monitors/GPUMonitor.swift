import Foundation
import IOKit

struct GPUSample: Sendable {
    /// GPU 全体の使用率 0.0〜1.0
    var utilization: Double = 0
    /// レンダラ使用率
    var renderer: Double = 0
    /// タイラ（ジオメトリ処理）使用率
    var tiler: Double = 0
    /// GPU が確保しているシステムメモリ（Apple Silicon はユニファイドメモリ）
    var allocatedMemory: UInt64 = 0
    var inUseMemory: UInt64 = 0
    var available: Bool = false
}

/// AGXAccelerator の PerformanceStatistics から GPU 使用率を読む。
/// Apple Silicon の GPU ドライバが公開している値で、追加権限は不要。
final class GPUMonitor {
    func sample() -> GPUSample {
        var result = GPUSample()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = unmanaged?.takeRetainedValue() as? [String: Any],
                  let stats = props["PerformanceStatistics"] as? [String: Any] else { continue }

            func number(_ key: String) -> Double? { (stats[key] as? NSNumber)?.doubleValue }

            // 統合 GPU が複数見つかった場合は最も高い使用率を採用する。
            let util = (number("Device Utilization %") ?? number("GPU Activity(%)") ?? 0) / 100
            if util >= result.utilization || !result.available {
                result.utilization = min(1, util)
                result.renderer = min(1, (number("Renderer Utilization %") ?? 0) / 100)
                result.tiler = min(1, (number("Tiler Utilization %") ?? 0) / 100)
                result.allocatedMemory = UInt64(max(0, number("Alloc system memory") ?? 0))
                result.inUseMemory = UInt64(max(0, number("In use system memory") ?? 0))
            }
            result.available = true
        }
        return result
    }

    /// GPU 名とコア数（起動時に一度だけ取得）。
    static func staticGPUInfo() -> (name: String, coreCount: Int) {
        var name = "Apple GPU"
        var cores = 0

        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault,
                                        IOServiceMatching("IOAccelerator"),
                                        &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                defer {
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }
                var buf = [CChar](repeating: 0, count: 128)
                if IORegistryEntryGetName(service, &buf) == KERN_SUCCESS {
                    let raw = String(cString: buf)
                    if !raw.isEmpty { name = raw }
                }
                let coreProperty = IORegistryEntrySearchCFProperty(
                    service, kIOServicePlane, "gpu-core-count" as CFString,
                    kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
                )
                if let number = coreProperty as? NSNumber {
                    cores = number.intValue
                } else if let data = coreProperty as? Data, data.count >= 4 {
                    // 一部のキーはリトルエンディアンのバイト列で返る。
                    cores = Int(data.prefix(4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                }
            }
        }

        // "AGXAcceleratorG16G" のような内部名より、チップ名ベースの表示のほうが分かりやすい。
        if let brand = Sysctl.string("machdep.cpu.brand_string"), brand.contains("Apple") {
            name = "\(brand) GPU"
        }
        return (name, cores)
    }
}
