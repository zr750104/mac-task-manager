import Foundation
import IOKit

enum SensorCategory: Int, Sendable, CaseIterable, Comparable {
    case soc
    case performanceCore
    case efficiencyCore
    case gpu
    case neuralEngine
    case storage
    case battery
    case power
    case board
    case other

    var label: String {
        switch self {
        case .soc: return "SoC ダイ（CPU・GPU 共通）"
        case .performanceCore: return "P コア"
        case .efficiencyCore: return "E コア"
        case .gpu: return "GPU"
        case .neuralEngine: return "Neural Engine"
        case .storage: return "ストレージ（SSD）"
        case .battery: return "バッテリー"
        case .power: return "電源部"
        case .board: return "補助チップ・基板"
        case .other: return "その他"
        }
    }

    /// この機種で何を指しているかの補足。
    var note: String? {
        switch self {
        case .soc:
            return "チップ本体の温度。CPU と GPU は同じダイ上にあるため、負荷をかけるとどちらでも上昇します。"
        case .storage:
            return "内蔵 SSD の温度。CPU / GPU 負荷では変化しません。"
        case .power:
            return "電源まわりの温度。"
        case .board:
            return "CPU / GPU 負荷にほとんど反応しない、別ドメインのセンサーです。"
        default:
            return nil
        }
    }

    static func < (lhs: SensorCategory, rhs: SensorCategory) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TemperatureSensor: Sendable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var celsius: Double
    var category: SensorCategory
}

struct TemperatureSample: Sendable {
    var available = false
    var sensors: [TemperatureSensor] = []

    /// チップ本体の代表値（最も熱いコア/ダイの温度）。
    var socMax: Double = 0
    var socAverage: Double = 0
    /// 全センサー中の最高温度。
    var overallMax: Double = 0

    func sensors(in category: SensorCategory) -> [TemperatureSensor] {
        sensors.filter { $0.category == category }
    }

    func max(in category: SensorCategory) -> Double? {
        sensors(in: category).map(\.celsius).max()
    }

    /// 表示順に並べたカテゴリ一覧。
    var categories: [SensorCategory] {
        Array(Set(sensors.map(\.category))).sorted()
    }
}

/// Apple Silicon の温度センサーを読む。
///
/// IOKit の HID サブシステムがベンダー定義の温度センサー（usage page 0xff00 / usage 0x0005）を
/// 公開しており、**管理者権限なし**で読める。`powermetrics` と違い sudo は不要。
/// ただしこれらの関数は公開 API ではないため、dlsym で解決し、
/// 取得できない環境では温度表示を無効化する（アプリは通常どおり動作する）。
final class TemperatureMonitor {

    // MARK: - 非公開 IOKit HID API

    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject?, CFDictionary?) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject?, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (AnyObject?, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatValue = @convention(c) (AnyObject?, Int32) -> Double

    private struct API {
        var createClient: CreateClient
        var setMatching: SetMatching
        var copyServices: CopyServices
        var copyProperty: CopyProperty
        var copyEvent: CopyEvent
        var getFloatValue: GetFloatValue
    }

    /// kIOHIDEventTypeTemperature
    private static let temperatureEventType: Int32 = 15
    /// kHIDPage_AppleVendor
    private static let appleVendorUsagePage = 0xff00
    /// kHIDUsage_AppleVendor_TemperatureSensor
    private static let temperatureSensorUsage = 0x0005

    private static let api: API? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            return nil
        }
        func load<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let create = load("IOHIDEventSystemClientCreate", CreateClient.self),
              let matching = load("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let services = load("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let property = load("IOHIDServiceClientCopyProperty", CopyProperty.self),
              let event = load("IOHIDServiceClientCopyEvent", CopyEvent.self),
              let value = load("IOHIDEventGetFloatValue", GetFloatValue.self) else { return nil }
        return API(createClient: create, setMatching: matching, copyServices: services,
                   copyProperty: property, copyEvent: event, getFloatValue: value)
    }()

    // MARK: - 状態

    private var client: AnyObject?
    private var services: [AnyObject] = []
    private var names: [String] = []
    private var isUnavailable = false

    // MARK: - 取得

    func sample() -> TemperatureSample {
        var result = TemperatureSample()
        guard !isUnavailable, let api = Self.api else { return result }

        if client == nil {
            guard connect(api) else {
                isUnavailable = true
                return result
            }
        }
        guard !services.isEmpty else { return result }

        var sensors: [TemperatureSensor] = []
        sensors.reserveCapacity(services.count)
        for (index, service) in services.enumerated() {
            guard let event = api.copyEvent(service, Int64(Self.temperatureEventType), 0, 0)?
                .takeRetainedValue() else { continue }
            // IOHIDEventFieldBase(type) = type << 16
            let celsius = api.getFloatValue(event, Self.temperatureEventType << 16)
            // 未接続センサーは 0 や異常値を返すため、現実的な範囲だけ採用する。
            guard celsius > 0, celsius < 150 else { continue }
            let name = index < names.count ? names[index] : "センサー \(index)"
            guard !Self.isCalibrationReference(name) else { continue }
            sensors.append(TemperatureSensor(name: name, celsius: celsius,
                                             category: Self.category(for: name)))
        }

        guard !sensors.isEmpty else { return result }
        result.available = true
        result.sensors = sensors.sorted { ($0.category, -$0.celsius) < ($1.category, -$1.celsius) }
        result.overallMax = sensors.map(\.celsius).max() ?? 0

        // チップ本体の代表値。コア別センサーがある機種ではそちらを優先する。
        let coreCategories: [SensorCategory] = [.performanceCore, .efficiencyCore, .gpu, .soc]
        let socSensors = sensors.filter { coreCategories.contains($0.category) }
        let target = socSensors.isEmpty ? sensors : socSensors
        result.socMax = target.map(\.celsius).max() ?? 0
        result.socAverage = target.map(\.celsius).reduce(0, +) / Double(target.count)
        return result
    }

    private func connect(_ api: API) -> Bool {
        guard let newClient = api.createClient(kCFAllocatorDefault)?.takeRetainedValue() else {
            return false
        }
        let matching: [String: Int] = [
            "PrimaryUsagePage": Self.appleVendorUsagePage,
            "PrimaryUsage": Self.temperatureSensorUsage
        ]
        _ = api.setMatching(newClient, matching as CFDictionary)
        guard let found = api.copyServices(newClient)?.takeRetainedValue() as? [AnyObject],
              !found.isEmpty else { return false }

        client = newClient
        services = found
        // センサー名は変わらないので一度だけ読む。
        names = found.map { service in
            (api.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String)
                ?? "センサー"
        }
        return true
    }

    /// 校正用の基準センサー。温度としては常に一定値を返すため一覧から除外する
    /// （負荷試験でも変化量が 0.0℃ だった）。
    private static func isCalibrationReference(_ name: String) -> Bool {
        name.lowercased().contains("tcal")
    }

    /// センサー名からカテゴリを推定する。
    ///
    /// 名前は機種によって異なる。ノート系の Apple Silicon は
    /// "pACC MTR Temp Sensor1" のようにコア別の名前を公開するが、
    /// M4 Mac mini は "PMU tdie1" のような汎用名しか出さない。
    /// そこで M4 実機で CPU 全コア負荷と GPU 負荷をかけ、各センサーの上昇幅を測って分類した:
    ///
    /// - `PMU tdie1〜14` : CPU 負荷で最大 +14.7℃、GPU 負荷で最大 +10.2℃ → SoC ダイ本体
    /// - `PMU2 tdie*`    : どちらの負荷でも +1℃ 程度 → 別ドメイン（基板側）
    /// - `PMU tdev*`     : +2〜4℃ → 電源部
    /// - `NAND CH0 temp` : CPU/GPU 負荷で +0.0℃ → SSD
    private static func category(for name: String) -> SensorCategory {
        let lower = name.lowercased()
        if lower.contains("pacc") { return .performanceCore }
        if lower.contains("eacc") { return .efficiencyCore }
        if lower.contains("gpu") { return .gpu }
        if lower.contains("ane") || lower.contains("neural") { return .neuralEngine }
        if lower.contains("nand") || lower.contains("ssd") || lower.contains("flash") { return .storage }
        if lower.contains("batt") || lower.contains("gas gauge") { return .battery }
        // 第 2 PMU 配下のダイ温度は CPU/GPU の負荷に追従しないので分けて扱う。
        if lower.hasPrefix("pmu2") { return lower.contains("tdie") ? .board : .power }
        if lower.contains("tdie") || lower.contains("soc") { return .soc }
        if lower.contains("tdev") || lower.contains("pmu") { return .power }
        return .other
    }
}
