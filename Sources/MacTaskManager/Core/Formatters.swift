import Foundation

enum Fmt {
    /// 1024 進のバイト表記（GB / MB など）。
    static func bytes(_ value: UInt64, decimals: Int? = nil) -> String {
        bytes(Double(value), decimals: decimals)
    }

    static func bytes(_ value: Double, decimals: Int? = nil) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = max(0, value)
        var unit = 0
        while v >= 1024, unit < units.count - 1 {
            v /= 1024
            unit += 1
        }
        let digits = decimals ?? (unit >= 3 ? 2 : (v < 10 && unit > 0 ? 1 : 0))
        return String(format: "%.\(digits)f %@", v, units[unit])
    }

    /// 転送速度。
    static func rate(_ bytesPerSec: Double) -> String {
        bytes(bytesPerSec, decimals: bytesPerSec < 1024 * 1024 ? 0 : 1) + "/s"
    }

    /// メニューバー向けの短い転送速度。「1.2M」「340K」のように単位を 1 文字にする。
    /// 幅を固定して表示するため、数字は最大 3 桁に収める。
    /// 1000 を超えたら次の単位へ上げるので「1023K」のような 4 桁にはならない（→「1.0M」）。
    static func compactRate(_ bytesPerSec: Double) -> String {
        let v = max(0, bytesPerSec)
        if v < 1000 { return String(format: "%.0f", v) }
        let units = ["K", "M", "G", "T"]
        var value = v / 1024
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: value < 10 ? "%.1f%@" : "%.0f%@", value, units[unit])
    }

    static func percent(_ ratio: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f%%", ratio * 100)
    }

    /// CPU 使用率（100% = 1 コア占有）。
    static func cpuPercent(_ percent: Double) -> String {
        String(format: percent >= 100 ? "%.0f%%" : "%.1f%%", percent)
    }

    /// 秒数を「3日 04:12:33」形式へ。
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let d = total / 86_400
        let h = (total % 86_400) / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if d > 0 { return String(format: "%d日 %02d:%02d:%02d", d, h, m, s) }
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// プロセスの累積 CPU 時間（Activity Monitor 風の 時:分:秒.100分の1秒）。
    static func cpuTime(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = total.truncatingRemainder(dividingBy: 60)
        if h > 0 { return String(format: "%d:%02d:%05.2f", h, m, s) }
        return String(format: "%d:%05.2f", m, s)
    }

    static func count(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
