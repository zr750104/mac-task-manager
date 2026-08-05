import Foundation
import Darwin

struct NetworkInterfaceSample: Sendable, Identifiable {
    var id: String { name }
    var name: String
    var displayName: String
    var downloadRate: Double = 0
    var uploadRate: Double = 0
    var totalReceived: UInt64 = 0
    var totalSent: UInt64 = 0
    var packetsIn: UInt64 = 0
    var packetsOut: UInt64 = 0
    var isActive: Bool = false
}

struct NetworkSample: Sendable {
    var downloadRate: Double = 0
    var uploadRate: Double = 0
    var totalReceived: UInt64 = 0
    var totalSent: UInt64 = 0
    var packetsInPerSec: Double = 0
    var packetsOutPerSec: Double = 0
    var interfaces: [NetworkInterfaceSample] = []
}

/// getifaddrs の if_data から NIC ごとの累積バイト数を読み、差分で速度を出す。
final class NetworkMonitor {
    private struct Counters {
        var received: UInt64
        var sent: UInt64
        var packetsIn: UInt64
        var packetsOut: UInt64
    }

    private var previous: [String: Counters] = [:]
    private var previousTime: Date?

    func sample() -> NetworkSample {
        var result = NetworkSample()
        var current: [String: Counters] = [:]

        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return result }
        defer { freeifaddrs(addrs) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_LINK),
                  let dataPtr = entry.pointee.ifa_data else { continue }

            let name = String(cString: entry.pointee.ifa_name)
            // ループバックは実トラフィックではないため除外する。
            guard name != "lo0" else { continue }

            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            current[name] = Counters(received: UInt64(data.ifi_ibytes),
                                     sent: UInt64(data.ifi_obytes),
                                     packetsIn: UInt64(data.ifi_ipackets),
                                     packetsOut: UInt64(data.ifi_opackets))
        }

        let now = Date()
        let dt = previousTime.map { now.timeIntervalSince($0) } ?? 0

        var interfaces: [NetworkInterfaceSample] = []
        for (name, counters) in current {
            var iface = NetworkInterfaceSample(name: name, displayName: Self.friendlyName(for: name))
            iface.totalReceived = counters.received
            iface.totalSent = counters.sent
            iface.packetsIn = counters.packetsIn
            iface.packetsOut = counters.packetsOut

            if dt > 0, let prev = previous[name] {
                // 32bit カウンタの巻き戻り時は 0 とみなす。
                iface.downloadRate = counters.received >= prev.received ? Double(counters.received - prev.received) / dt : 0
                iface.uploadRate = counters.sent >= prev.sent ? Double(counters.sent - prev.sent) / dt : 0
                if counters.packetsIn >= prev.packetsIn {
                    result.packetsInPerSec += Double(counters.packetsIn - prev.packetsIn) / dt
                }
                if counters.packetsOut >= prev.packetsOut {
                    result.packetsOutPerSec += Double(counters.packetsOut - prev.packetsOut) / dt
                }
            }
            // 通信中か、まとまった通信実績があるものだけ一覧に出す。
            // これをしないと未使用の utun（VPN）が大量に並んでしまう。
            let cumulative = counters.received + counters.sent
            iface.isActive = (iface.downloadRate + iface.uploadRate) > 0 || cumulative > 10 * 1024 * 1024
            result.downloadRate += iface.downloadRate
            result.uploadRate += iface.uploadRate
            result.totalReceived += counters.received
            result.totalSent += counters.sent
            interfaces.append(iface)
        }

        previous = current
        previousTime = now

        // 今まさに通信しているものを上に、次いで累計の多い順。
        result.interfaces = interfaces
            .filter(\.isActive)
            .sorted {
                let left = ($0.downloadRate + $0.uploadRate, $0.totalReceived + $0.totalSent)
                let right = ($1.downloadRate + $1.uploadRate, $1.totalReceived + $1.totalSent)
                return left > right
            }
        return result
    }

    private static func friendlyName(for bsd: String) -> String {
        switch bsd {
        case "en0": return "Wi-Fi / Ethernet (en0)"
        case let n where n.hasPrefix("en"): return "Ethernet (\(n))"
        case let n where n.hasPrefix("utun"), let n where n.hasPrefix("ipsec"): return "VPN (\(bsd))"
        case let n where n.hasPrefix("bridge"): return "ブリッジ (\(n))"
        case "awdl0": return "AirDrop (awdl0)"
        case let n where n.hasPrefix("llw"): return "低遅延無線 (\(n))"
        case "gif0", "stf0": return "トンネル (\(bsd))"
        default: return bsd
        }
    }
}
