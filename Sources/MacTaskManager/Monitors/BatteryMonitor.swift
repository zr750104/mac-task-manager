import Foundation
import IOKit

struct BatterySample: Sendable {
    /// バッテリーを積んでいない機種（Mac mini / Mac Studio など）では false。
    var available = false
    /// 充電残量 0.0〜1.0
    var charge: Double = 0
    var isCharging = false
    /// 電源アダプタに接続されているか
    var isPluggedIn = false
    var isFullyCharged = false
    var cycleCount = 0
    /// 最大容量 ÷ 設計容量。バッテリーの劣化具合。
    var health: Double = 0
    /// "Normal" / "Service Recommended" など
    var condition: String = ""
    /// 摂氏。取得できない場合は nil。
    var temperature: Double?
    /// 放電中は負、充電中は正（W）
    var wattage: Double = 0
    var voltage: Double = 0
    /// 残り時間（分）。算出中は nil。
    var minutesRemaining: Int?

    var healthLabel: String {
        health > 0 ? String(format: "%.0f%%", health * 100) : "—"
    }

    var stateLabel: String {
        if !isPluggedIn { return "バッテリー駆動" }
        if isFullyCharged { return "満充電" }
        if isCharging { return "充電中" }
        return "電源接続"
    }
}

/// AppleSmartBattery からノート型 Mac のバッテリー情報を読む。追加権限は不要。
final class BatteryMonitor {
    private var isUnavailable = false

    func sample() -> BatterySample {
        var result = BatterySample()
        guard !isUnavailable else { return result }

        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            // デスクトップ機にはこのサービスが存在しない。以後は探しに行かない。
            isUnavailable = true
            return result
        }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any] else { return result }

        func integer(_ key: String) -> Int? { (values[key] as? NSNumber)?.intValue }
        func boolean(_ key: String) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }

        let current = integer("CurrentCapacity") ?? 0
        let maximum = integer("MaxCapacity") ?? 0
        let design = integer("DesignCapacity") ?? 0

        result.available = maximum > 0
        guard result.available else { return result }

        result.charge = min(1, Double(current) / Double(maximum))
        result.isCharging = boolean("IsCharging")
        result.isPluggedIn = boolean("ExternalConnected")
        result.isFullyCharged = boolean("FullyCharged")
        result.cycleCount = integer("CycleCount") ?? 0
        // Apple Silicon では CurrentCapacity / MaxCapacity が「%」（最大 100）で返る。
        // 劣化度は mAh 同士で比べる必要があるので、AppleRawMaxCapacity（mAh）を優先する。
        // Intel 機など AppleRaw が無い機種では MaxCapacity が mAh なのでそちらを使う。
        let fullChargeMAh = integer("AppleRawMaxCapacity") ?? integer("NominalChargeCapacity")
            ?? (maximum > 100 ? maximum : 0)
        if design > 0, fullChargeMAh > 0 {
            result.health = min(1, Double(fullChargeMAh) / Double(design))
        }
        result.condition = (values["BatteryHealthCondition"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "正常"

        // 温度は 0.01℃ 単位の整数で入っている。
        if let raw = integer("Temperature"), raw > 0 {
            result.temperature = Double(raw) / 100
        }

        // 電流(mA) × 電圧(mV) → W。放電中は電流が負で返る。
        let milliVolts = integer("Voltage") ?? 0
        let milliAmps = integer("Amperage") ?? 0
        result.voltage = Double(milliVolts) / 1000
        result.wattage = Double(milliAmps) * Double(milliVolts) / 1_000_000

        // 満充電/計算中は極端な値が入るため、現実的な範囲だけ採用する。
        let remaining = integer("TimeRemaining")
        if let remaining, remaining > 0, remaining < 60 * 24 {
            result.minutesRemaining = remaining
        }
        return result
    }
}
