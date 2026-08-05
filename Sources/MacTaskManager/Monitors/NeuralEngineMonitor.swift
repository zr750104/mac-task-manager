import Foundation

struct NeuralEngineSample: Sendable {
    var available = false
    /// ANE の消費電力（W）
    var watts: Double = 0
    /// ANE からの割り込み回数（毎秒）。推論の実行回数の目安になる。
    var operationsPerSecond: Double = 0
    /// これまでに観測した最大電力。使用率の分母に使う。
    var referencePeak: Double = 0
    /// 観測した最大電力に対する比率（0〜1）
    var utilization: Double = 0

    /// 目に見えるレベルで動いているか
    var isActive: Bool { watts > 0.02 || operationsPerSecond > 1 }

    var stateLabel: String { isActive ? "動作中" : "待機中" }
}

/// Neural Engine（NPU）の稼働状況を取得する。
///
/// Apple は GPU の "Device Utilization %" に相当する **ANE の使用率を公開していない**。
/// そこで実機で Vision の画像分類を回して反応するチャンネルを調べ、
/// 次の 2 つが確実に動くことを確認したうえで指標にしている:
///
/// - `Energy Model` の `ANE`（消費電力）: アイドル 0.005W → 負荷時 1.52W と 300 倍以上変化
/// - `Interrupt Statistics (by index)` の `ane 0` 割り込み回数: 8 秒あたり 3 回 → 9,642 回
///
/// 使用率は「観測した最大電力に対する比率」で、絶対的な稼働率ではない。
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
    /// 起動してからの最大電力。低すぎる値で割ると常に 100% になるので下限を設ける。
    private var peakWatts: Double = 0.5

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
        peakWatts = max(peakWatts, result.watts)
        result.referencePeak = peakWatts
        result.utilization = peakWatts > 0 ? min(1, result.watts / peakWatts) : 0
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
