import Foundation
import IOKit
import IOKit.storage

struct VolumeInfo: Sendable, Identifiable {
    var id: String { path }
    var name: String
    var path: String
    var total: UInt64
    var free: UInt64
    var used: UInt64 { total > free ? total - free : 0 }
    var usedRatio: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// 物理ディスク 1 台ぶんの I/O。
struct PhysicalDisk: Sendable, Identifiable {
    var id: String { bsdName }
    /// "disk0" など
    var bsdName: String
    /// "WD Blue SN5000 1TB" のような製品名
    var productName: String
    /// "USB" / "Apple Fabric" など
    var connection: String
    var isInternal: Bool
    var readRate: Double = 0
    var writeRate: Double = 0
    var totalRead: UInt64 = 0
    var totalWritten: UInt64 = 0

    var displayName: String {
        productName.isEmpty ? bsdName : productName
    }
    var locationLabel: String {
        isInternal ? "内蔵" : "外付け（\(connection)）"
    }
}

struct DiskSample: Sendable {
    var readRate: Double = 0
    var writeRate: Double = 0
    var readsPerSec: Double = 0
    var writesPerSec: Double = 0
    var totalRead: UInt64 = 0
    var totalWritten: UInt64 = 0
    var volumes: [VolumeInfo] = []
    var disks: [PhysicalDisk] = []
}

/// IOBlockStorageDriver の Statistics から読み書きバイト数を取得する。
final class DiskMonitor {
    private struct Counters {
        var bytesRead: UInt64 = 0
        var bytesWritten: UInt64 = 0
        var reads: UInt64 = 0
        var writes: UInt64 = 0
    }

    private var previous = Counters()
    private var previousTime: Date?
    private var previousPerDisk: [String: Counters] = [:]
    private var volumeCache: [VolumeInfo] = []
    private var volumeCacheTime: Date?

    func sample() -> DiskSample {
        var result = DiskSample()
        var current = Counters()
        var perDisk: [String: Counters] = [:]
        var descriptions: [String: PhysicalDisk] = [:]

        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault,
                                        IOServiceMatching("IOBlockStorageDriver"),
                                        &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                defer {
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }
                guard let stats = IORegistryEntryCreateCFProperty(
                    service, kIOBlockStorageDriverStatisticsKey as CFString,
                    kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { continue }

                func value(_ key: String) -> UInt64 {
                    UInt64(max(0, (stats[key] as? NSNumber)?.int64Value ?? 0))
                }
                let counters = Counters(bytesRead: value(kIOBlockStorageDriverStatisticsBytesReadKey),
                                        bytesWritten: value(kIOBlockStorageDriverStatisticsBytesWrittenKey),
                                        reads: value(kIOBlockStorageDriverStatisticsReadsKey),
                                        writes: value(kIOBlockStorageDriverStatisticsWritesKey))
                current.bytesRead += counters.bytesRead
                current.bytesWritten += counters.bytesWritten
                current.reads += counters.reads
                current.writes += counters.writes

                if let disk = describe(service: service) {
                    perDisk[disk.bsdName] = counters
                    descriptions[disk.bsdName] = disk
                }
            }
        }

        let now = Date()
        if let prevTime = previousTime {
            let dt = now.timeIntervalSince(prevTime)
            if dt > 0 {
                result.readRate = current.bytesRead >= previous.bytesRead
                    ? Double(current.bytesRead - previous.bytesRead) / dt : 0
                result.writeRate = current.bytesWritten >= previous.bytesWritten
                    ? Double(current.bytesWritten - previous.bytesWritten) / dt : 0
                result.readsPerSec = current.reads >= previous.reads
                    ? Double(current.reads - previous.reads) / dt : 0
                result.writesPerSec = current.writes >= previous.writes
                    ? Double(current.writes - previous.writes) / dt : 0
            }
        }
        // 物理ディスクごとの速度。外付けドライブの活動もこれで見える。
        var disks: [PhysicalDisk] = []
        let elapsed = previousTime.map { now.timeIntervalSince($0) } ?? 0
        for (bsdName, counters) in perDisk {
            guard var disk = descriptions[bsdName] else { continue }
            disk.totalRead = counters.bytesRead
            disk.totalWritten = counters.bytesWritten
            if elapsed > 0, let prev = previousPerDisk[bsdName] {
                if counters.bytesRead >= prev.bytesRead {
                    disk.readRate = Double(counters.bytesRead - prev.bytesRead) / elapsed
                }
                if counters.bytesWritten >= prev.bytesWritten {
                    disk.writeRate = Double(counters.bytesWritten - prev.bytesWritten) / elapsed
                }
            }
            disks.append(disk)
        }
        // 内蔵を先に、あとは活動量の多い順。
        result.disks = disks.sorted {
            ($0.isInternal ? 0 : 1, -($0.readRate + $0.writeRate))
                < ($1.isInternal ? 0 : 1, -($1.readRate + $1.writeRate))
        }

        previous = current
        previousPerDisk = perDisk
        previousTime = now
        result.totalRead = current.bytesRead
        result.totalWritten = current.bytesWritten
        result.volumes = volumes()
        return result
    }

    /// IOBlockStorageDriver から、その物理ディスクの BSD 名と製品名・接続方式を取り出す。
    private func describe(service: io_registry_entry_t) -> PhysicalDisk? {
        // BSD 名は子の IOMedia が持っている（disk0 のような whole disk 名）。
        var media: io_registry_entry_t = 0
        guard IORegistryEntryGetChildEntry(service, kIOServicePlane, &media) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(media) }
        guard let bsdName = IORegistryEntryCreateCFProperty(
            media, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else { return nil }

        // 製品名と接続方式は親の IOBlockStorageDevice 側にある。
        var product = ""
        var connection = ""
        var isInternal = true
        var parent: io_registry_entry_t = 0
        if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
            defer { IOObjectRelease(parent) }
            if let characteristics = IORegistryEntryCreateCFProperty(
                parent, "Device Characteristics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                let vendor = (characteristics["Vendor Name"] as? String ?? "")
                    .trimmingCharacters(in: .whitespaces)
                let name = (characteristics["Product Name"] as? String ?? "")
                    .trimmingCharacters(in: .whitespaces)
                product = [vendor, name].filter { !$0.isEmpty }.joined(separator: " ")
            }
            if let characteristics = IORegistryEntryCreateCFProperty(
                parent, "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                connection = characteristics["Physical Interconnect"] as? String ?? ""
                let location = characteristics["Physical Interconnect Location"] as? String ?? ""
                isInternal = location != "External"
            }
        }
        return PhysicalDisk(bsdName: bsdName, productName: product,
                            connection: connection, isInternal: isInternal)
    }

    /// ボリューム容量は頻繁に変わらないので 5 秒キャッシュする。
    private func volumes() -> [VolumeInfo] {
        if let cached = volumeCacheTime, Date().timeIntervalSince(cached) < 5 {
            return volumeCache
        }
        var list: [VolumeInfo] = []
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeIsBrowsableKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true,
                  let total = values.volumeTotalCapacity, total > 0 else { continue }
            let free = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) } ?? 0
            list.append(VolumeInfo(name: values.volumeName ?? url.lastPathComponent,
                                   path: url.path,
                                   total: UInt64(total),
                                   free: free))
        }
        // 起動ボリュームを先頭にする。
        list.sort { ($0.path == "/" ? 0 : 1, $0.name) < ($1.path == "/" ? 0 : 1, $1.name) }
        volumeCache = list
        volumeCacheTime = Date()
        return list
    }
}
