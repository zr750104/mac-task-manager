import Foundation

struct NeuralEngineSample: Sendable {
    var available = false
    /// ANE の消費電力（W）
    var watts: Double = 0
    /// ANE からの割り込み回数（毎秒）。推論の実行回数の目安になる。
    var operationsPerSecond: Double = 0
    /// 使用率の分母に使う基準（推論リクエスト/秒）
    var referenceRate: Double = 0
    /// 基準に対する推論リクエスト/秒の比率（0〜1）。CPU 使用率と同じ感覚で読める値。
    var utilization: Double = 0

    /// 目に見えるレベルで動いているか。
    /// 使用率が 1% 未満（0% と表示される）なのに「動作中」と出ないよう、基準の 1% をしきい値にする。
    var isActive: Bool {
        available && (watts > 0.02 || operationsPerSecond >= max(1, referenceRate * 0.01))
    }

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
/// 使用率は **推論リクエスト/秒（割り込み回数）を基準の回数で割って**求めている。
/// 以前は消費電力を基準電力で割っていたが、macOS 27 では `Energy Model` の ANE が
/// 負荷をかけても常に 0 になり（2026-11 実測）、使用率が 0% のまま動かなくなったため切り替えた。
/// 割り込み回数は macOS 27 でも動く（待機中 0 回/秒 → 8 並列の画像分類で約 1,000〜1,500 回/秒）。
///
/// ハードウェアが報告する稼働率そのものではなく**推論の処理回数**なので、
/// 軽い推論を 1 本回すだけでも高めに出る（1 並列で約 950 回/秒）。
/// 逆に 1 回の推論が重いモデルは、NPU がフルに動いていても低めに出ることがある。
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

    /// ANE の消費電力として考えられる上限（W）。電力の表示で、これを超える値は計測の誤りとして捨てる
    /// （以前、一瞬だけ 126 W と出た値が使用率の基準として保存され、使用率がほぼ 0% のままになっていた）。
    static let plausibleMaxWatts: Double = 20

    private static let referenceKey = "neuralEngineReferenceRate"
    /// 電力を基準にしていた頃の保存キー。もう使わないので消す。
    private static let legacyReferenceKey = "neuralEngineReferenceWatts"

    private var reference = NeuralEngineReference(
        storedRate: UserDefaults.standard.object(forKey: NeuralEngineMonitor.referenceKey) as? Double)

    init() {
        UserDefaults.standard.removeObject(forKey: Self.legacyReferenceKey)
        if reference.rate != (UserDefaults.standard.object(forKey: Self.referenceKey) as? Double) {
            // 壊れた保存値を既定値に戻した場合など。保存値と揃えておく。
            UserDefaults.standard.removeObject(forKey: Self.referenceKey)
        }
    }

    /// 使用率の基準を実測の既定値に戻す。
    /// 計測は別スレッド（Sampler）で動くので、ここでは保存値を消すだけにして、
    /// 次回の計測時にそれを見て基準を戻す（再起動を待たずに反映される）。
    static func resetReference() {
        UserDefaults.standard.removeObject(forKey: referenceKey)
    }

    /// - Parameter watts: PowerMonitor が取得した ANE の消費電力（表示用。使用率の計算には使わない）
    func sample(watts: Double) -> NeuralEngineSample {
        var result = NeuralEngineSample()
        result.watts = watts.isFinite && watts >= 0 && watts <= Self.plausibleMaxWatts ? watts : 0

        if !isUnavailable, let api = Self.api {
            if subscription == nil, !connect(api) {
                isUnavailable = true
            } else {
                result.operationsPerSecond = interruptRate(api)
            }
        }
        // 使用率は割り込み回数から出すので、それが読めなければ「取得できない」扱いにする（0% と区別する）。
        result.available = !isUnavailable && Self.api != nil

        // 「基準を戻す」で保存値が消されていたら、既定値に戻す（超過 1 回目の記録も消す）。
        if UserDefaults.standard.object(forKey: Self.referenceKey) == nil, !reference.isPristine {
            reference = NeuralEngineReference(storedRate: nil)
        }
        if result.available, reference.observe(result.operationsPerSecond) {
            UserDefaults.standard.set(reference.rate, forKey: Self.referenceKey)
        }
        result.referenceRate = reference.rate
        result.utilization = result.available ? reference.utilization(of: result.operationsPerSecond) : 0
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
        // チャンネルが 1 つも無い機種では、購読できても回数は取れないので「取得できない」扱いにする。
        let list = (subscribedChannels as NSDictionary)["IOReportChannels"] as? [Any] ?? []
        guard !list.isEmpty else { return false }
        subscription = newSubscription
        channels = subscribedChannels
        return true
    }
}

/// 推論リクエスト/秒から使用率を出すための基準。試験しやすいよう計測から切り離している。
struct NeuralEngineReference {
    /// 既定の基準（回/秒）。M4 Mac mini で Vision の画像分類を 8 スレッド並列で回したときの
    /// 実測（約 1,000〜1,500 回/秒、平均でおよそ 1,200 回/秒）。
    static let defaultRate: Double = 1_200
    /// これを超える回数は計測の誤りとみなす（実測の 100 倍以上）。
    static let plausibleMaxRate: Double = 200_000
    /// 基準を自動で上げる上限（既定の 10 倍）。処理回数の多い軽いモデルを回したあと、
    /// 基準が上がりすぎて普段の推論がほとんど 0% に見えるのを防ぐ。
    static let maxReferenceRate: Double = defaultRate * 10

    private(set) var rate: Double
    /// 直前の計測で基準を超えた値。一瞬の跳ね上がりで基準を上げないよう、2 回続いたときだけ採用する。
    private var pending: Double?

    init(storedRate: Double?) {
        if let storedRate, storedRate.isFinite,
           storedRate >= Self.defaultRate, storedRate <= Self.maxReferenceRate {
            rate = storedRate
        } else {
            rate = Self.defaultRate
        }
    }

    /// 既定値のままで、超過の記録も無い（作り直す必要がない）
    var isPristine: Bool { rate == Self.defaultRate && pending == nil }

    /// 新しい計測値を見て、必要なら基準を引き上げる。引き上げたら true。
    /// 基準を超える値が 2 回続いたら低いほうまで上げる。1 回に上げるのは今の基準の 2 倍まで。
    mutating func observe(_ value: Double) -> Bool {
        guard value.isFinite, value >= 0, value <= Self.plausibleMaxRate, value > rate,
              rate < Self.maxReferenceRate else {
            pending = nil
            return false
        }
        guard let previous = pending else {
            pending = value
            return false
        }
        rate = min(previous, value, rate * 2, Self.maxReferenceRate)
        pending = nil
        return true
    }

    func utilization(of value: Double) -> Double {
        // ありえない値（計測の誤り）は 100% に張り付かせず、0% として扱う。
        guard value.isFinite, value > 0, value <= Self.plausibleMaxRate, rate > 0 else { return 0 }
        return min(1, value / rate)
    }
}
