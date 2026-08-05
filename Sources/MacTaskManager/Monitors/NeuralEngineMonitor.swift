import Foundation

struct NeuralEngineSample: Sendable {
    var available = false
    /// ANE の消費電力（W）
    var watts: Double = 0
    /// ANE からの割り込み回数（毎秒）。推論の実行回数の目安になる。
    var operationsPerSecond: Double = 0
    /// 使用率の分母に使う基準電力（W）
    var referencePeak: Double = 0
    /// 基準電力に対する比率（0〜1）。CPU 使用率と同じ感覚で読める値。
    var utilization: Double = 0

    /// 目に見えるレベルで動いているか
    var isActive: Bool { watts > 0.02 || operationsPerSecond > 1 }

    var stateLabel: String { isActive ? "動作中" : "待機中" }
}

/// Neural Engine（NPU）の稼働状況を取得する。
///
/// Apple は GPU の "Device Utilization %" に相当する **ANE の使用率を公開していない**
/// （`powermetrics` を root で動かしても電力しか出ない）。
/// そこで実機で Vision の画像分類を回して反応するチャンネルを調べ、
/// 次の 2 つが確実に動くことを確認したうえで指標にしている:
///
/// - `Energy Model` の `ANE`（消費電力）: アイドル 0.000W → 負荷時 2.0W
/// - `Interrupt Statistics (by index)` の `ane 0` 割り込み回数: 8 秒あたり 3 回 → 9,642 回
///
/// 使用率は消費電力を基準電力で割って求めている。ハードウェアが報告する
/// 稼働率そのものではないが、CPU 使用率と同じ感覚で読める値になる。
///
/// なお **GPU 使用率は NPU の使用率ではない**。実測でも NPU を全力で回している間、
/// GPU 使用率は 22.3% → 25.2% とほぼ動かなかった（GPU と ANE は別のハードウェア）。
final class NeuralEngineMonitor {

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
              let value = load("IOReportSimpleGetIntegerValue", ChannelGetInteger.self) else { return nil }
        return API(copyChannelsInGroup: group, createSubscription: subscribe,
                   createSamples: samples, createSamplesDelta: delta,
                   channelName: name, channelValue: value)
    }()

    private var subscription: UnsafeMutableRawPointer?
    private var channels: CFMutableDictionary?
    private var previousSample: CFDictionary?
    private var previousTime: Date?
    private var isUnavailable = false

    /// 使用率の分母。M4 Mac mini で Vision の画像分類を 8 スレッド並列で回したときの
    /// 実測ピークが 2.0 W だったので、これを既定値にしている。
    /// より重い推論でこれを超えたら基準を引き上げ、次回起動時も引き継ぐ。
    private static let defaultReferenceWatts: Double = 2.0
    private static let referenceKey = "neuralEngineReferenceWatts"

    private var referenceWatts: Double = {
        let stored = UserDefaults.standard.double(forKey: NeuralEngineMonitor.referenceKey)
        return max(stored, NeuralEngineMonitor.defaultReferenceWatts)
    }()

    /// 使用率の基準を実測の既定値に戻す。
    static func resetReference() {
        UserDefaults.standard.removeObject(forKey: referenceKey)
    }

    /// - Parameter watts: PowerMonitor が取得した ANE の消費電力
    func sample(watts: Double) -> NeuralEngineSample {
        var result = NeuralEngineSample()
        result.watts = max(0, watts)

        if !isUnavailable, let api = Self.api {
            if subscription == nil, !connect(api) {
                isUnavailable = true
            } else {
                result.operationsPerSecond = interruptRate(api)
            }
        }

        // 電力が取れていれば ANE の情報として意味がある。
        result.available = watts > 0 || result.operationsPerSecond > 0 || !isUnavailable

        // 基準を超える電力を観測したら、そこまで引き上げて記憶する。
        if result.watts > referenceWatts {
            referenceWatts = result.watts
            UserDefaults.standard.set(referenceWatts, forKey: Self.referenceKey)
        }
        result.referencePeak = referenceWatts
        result.utilization = referenceWatts > 0 ? min(1, result.watts / referenceWatts) : 0
        return result
    }

    private func interruptRate(_ api: API) -> Double {
        guard let subscription, let channels,
              let current = api.createSamples(subscription, channels, nil)?.takeRetainedValue() else {
            return 0
        }
        let now = Date()
        defer {
            previousSample = current
            previousTime = now
        }
        guard let previous = previousSample, let previousTime else { return 0 }
        let elapsed = now.timeIntervalSince(previousTime)
        guard elapsed > 0.05,
              let delta = api.createSamplesDelta(previous, current, nil)?.takeRetainedValue(),
              let dictionary = delta as? [String: Any],
              let list = dictionary["IOReportChannels"] as? [CFDictionary] else { return 0 }

        for channel in list {
            let name = api.channelName(channel)?.takeUnretainedValue() as String? ?? ""
            // 2 段目の割り込みハンドラの呼び出し回数が、推論 1 回ごとに増える。
            guard name.contains("Second Level Interrupt Handler Count") else { continue }
            let raw = api.channelValue(channel, 0)
            guard raw > 0 else { return 0 }
            return Double(raw) / elapsed
        }
        return 0
    }

    private func connect(_ api: API) -> Bool {
        guard let group = api.copyChannelsInGroup("Interrupt Statistics (by index)" as CFString,
                                                  "ane 0" as CFString, 0, 0, 0)?
            .takeRetainedValue() else { return false }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let newSubscription = api.createSubscription(nil, group, &subscribed, 0, nil),
              let subscribedChannels = subscribed?.takeRetainedValue() else { return false }
        subscription = newSubscription
        channels = subscribedChannels
        return true
    }
}
