import Foundation

struct PowerSample: Sendable {
    var available = false
    /// CPU 全体の消費電力（W）
    var cpu: Double = 0
    /// P コアクラスタ
    var performanceCores: Double = 0
    /// E コアクラスタ
    var efficiencyCores: Double = 0
    var gpu: Double = 0
    var dram: Double = 0
    var neuralEngine: Double = 0
    /// 取得できたその他のブロック（名前 → W）。上位のものだけ表示に使う。
    var others: [String: Double] = [:]

    /// 主要ブロックの合計。パッケージ全体の消費電力ではない点に注意。
    var majorTotal: Double { cpu + gpu + dram + neuralEngine }
}

/// IOReport の "Energy Model" グループから、ブロック別の消費電力を取得する。
///
/// Apple Silicon では CPU と GPU が同じダイに載っているため温度では両者を分離できないが、
/// 電力は別々に計測されている。`powermetrics` と違い **管理者権限は不要**。
/// libIOReport は公開 API ではないため dlsym で解決し、
/// 使えない環境では電力表示を無効化する。
final class PowerMonitor {

    private typealias CopyChannelsInGroup =
        @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription =
        @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
                        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
                        UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private typealias CreateSamples =
        @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta =
        @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelGetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias ChannelGetInteger = @convention(c) (CFDictionary, Int32) -> Int64

    private struct API {
        var copyChannelsInGroup: CopyChannelsInGroup
        var createSubscription: CreateSubscription
        var createSamples: CreateSamples
        var createSamplesDelta: CreateSamplesDelta
        var channelName: ChannelGetString
        var channelUnit: ChannelGetString
        var channelValue: ChannelGetInteger
    }

    private static let api: API? = {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }
        func load<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let group = load("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
              let subscribe = load("IOReportCreateSubscription", CreateSubscription.self),
              let samples = load("IOReportCreateSamples", CreateSamples.self),
              let delta = load("IOReportCreateSamplesDelta", CreateSamplesDelta.self),
              let name = load("IOReportChannelGetChannelName", ChannelGetString.self),
              let unit = load("IOReportChannelGetUnitLabel", ChannelGetString.self),
              let value = load("IOReportSimpleGetIntegerValue", ChannelGetInteger.self) else { return nil }
        return API(copyChannelsInGroup: group, createSubscription: subscribe,
                   createSamples: samples, createSamplesDelta: delta,
                   channelName: name, channelUnit: unit, channelValue: value)
    }()

    private var subscription: UnsafeMutableRawPointer?
    private var channels: CFMutableDictionary?
    private var previousSample: CFDictionary?
    private var previousTime: Date?
    private var isUnavailable = false

    func sample() -> PowerSample {
        var result = PowerSample()
        guard !isUnavailable, let api = Self.api else { return result }

        if subscription == nil, !connect(api) {
            isUnavailable = true
            return result
        }
        guard let subscription, let channels,
              let current = api.createSamples(subscription, channels, nil)?.takeRetainedValue() else {
            return result
        }

        let now = Date()
        defer {
            previousSample = current
            previousTime = now
        }
        guard let previous = previousSample, let previousTime else { return result }
        let elapsed = now.timeIntervalSince(previousTime)
        guard elapsed > 0.05,
              let delta = api.createSamplesDelta(previous, current, nil)?.takeRetainedValue(),
              let dictionary = delta as? [String: Any],
              let list = dictionary["IOReportChannels"] as? [CFDictionary] else { return result }

        var watts: [String: Double] = [:]
        for channel in list {
            // Get 系は +0 で返るため takeUnretainedValue を使う（Retained だと過剰解放になる）。
            let name = api.channelName(channel)?.takeUnretainedValue() as String? ?? ""
            let unit = (api.channelUnit(channel)?.takeUnretainedValue() as String? ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            let raw = api.channelValue(channel, 0)
            // カウンタが巻き戻ると負値になるので捨てる。
            guard raw > 0 else { continue }

            let joules: Double
            switch unit {
            case "mj": joules = Double(raw) / 1_000
            case "uj": joules = Double(raw) / 1_000_000
            case "nj": joules = Double(raw) / 1_000_000_000
            case "j": joules = Double(raw)
            default: continue
            }
            watts[name] = joules / elapsed
        }
        guard !watts.isEmpty else { return result }

        result.available = true
        result.performanceCores = watts["PCPU"] ?? 0
        result.efficiencyCores = watts["ECPU"] ?? 0
        result.cpu = watts["CPU Energy"] ?? (result.performanceCores + result.efficiencyCores)
        // "GPU Energy" は nJ 単位で桁溢れすることがあるため mJ の "GPU" を優先する。
        result.gpu = watts["GPU"] ?? watts["GPU Energy"] ?? 0
        result.dram = watts["DRAM"] ?? 0
        result.neuralEngine = watts["ANE"] ?? watts["ANE Energy"] ?? 0

        let known: Set<String> = ["PCPU", "ECPU", "CPU Energy", "GPU", "GPU Energy",
                                  "DRAM", "ANE", "ANE Energy"]
        result.others = watts.filter { !known.contains($0.key) && $0.value >= 0.01 }
        return result
    }

    private func connect(_ api: API) -> Bool {
        guard let group = api.copyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?
            .takeRetainedValue() else { return false }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let newSubscription = api.createSubscription(nil, group, &subscribed, 0, nil),
              let subscribedChannels = subscribed?.takeRetainedValue() else { return false }
        subscription = newSubscription
        channels = subscribedChannels
        return true
    }
}
