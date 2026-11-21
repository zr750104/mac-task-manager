import Foundation

/// Mac につながっている周辺機器 1 台ぶんのバッテリー。
struct DeviceBattery: Identifiable, Equatable, Sendable {
    enum Kind: Int, Sendable, Comparable {
        case iPhone, iPad, iPod, headphones, keyboard, mouse, trackpad, other

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

        /// 一般名。画面書き出しで実名の代わりに使う。
        var genericName: String {
            switch self {
            case .iPhone: return "iPhone"
            case .iPad: return "iPad"
            case .iPod: return "iPod touch"
            case .headphones: return "ヘッドホン"
            case .keyboard: return "キーボード"
            case .mouse: return "マウス"
            case .trackpad: return "トラックパッド"
            case .other: return "デバイス"
            }
        }

        var symbol: String {
            switch self {
            case .iPhone: return "iphone"
            case .iPad: return "ipad"
            case .iPod: return "ipodtouch"
            case .headphones: return "airpodspro"
            case .keyboard: return "keyboard"
            case .mouse: return "magicmouse"
            case .trackpad: return "rectangle.and.hand.point.up.left"
            case .other: return "battery.75percent"
            }
        }
    }

    /// 画面の中で同じ機器を見分けるためだけの識別子（保存はしない）
    var id: String
    /// 利用者が付けた名前（本名が入ることが多い）
    var name: String
    /// 機種名（例：iPad mini (A17 Pro)）。分かる機器だけ。
    var model: String?
    var kind: Kind
    /// 0〜1
    var level: Double
    var isCharging: Bool
    /// 接続の種類（USB / Wi-Fi / Bluetooth）
    var connection: String
    /// 今はつながっておらず、最後に記録された値（Bluetooth の未接続機器）
    var isStale = false
    /// 左右・ケースなど、部位ごとの残量（AirPods など）
    var detail: String?

    /// 一覧に出す補足（機種名・部位ごとの残量・接続の種類）
    var subtitle: String {
        var parts: [String] = []
        if let model, model != name { parts.append(model) }
        if let detail { parts.append(detail) }
        parts.append(isStale ? "前回の値" : connection)
        return parts.joined(separator: " · ")
    }
}

/// 周辺機器のバッテリー残量を集める。
///
/// - USB または Wi-Fi でつながる iPhone / iPad / iPod touch：
///   Finder の同期と同じ MobileDevice フレームワーク（非公開）。Wi-Fi は Finder の
///   「Wi-Fi 接続時にこのデバイスを表示」を有効にした機器で、同じネットワークにいるとき。
/// - Bluetooth 機器（AirPods、Apple 純正のマウス・キーボード・トラックパッド）：system_profiler。
///   未接続でも最後に記録された残量があれば「前回の値」として出す。
///
/// MobileDevice は非公開なのでリンクせず、実行時に読み込む。
/// 見つからない関数が 1 つでもあれば USB 機器の読み取りだけを止める（アプリは落とさない）。
/// 機器がロック中だと応答に数秒かかることがあるため、読み取りは専用のキューで行い、
/// 毎秒の計測（MetricsEngine.tick）を待たせない。
@MainActor
final class DeviceBatteryMonitor {
    static let shared = DeviceBatteryMonitor()

    /// 画面書き出しのときは実名（本名が入ることが多い）を一般名に置き換える。
    static var anonymizesNames = false

    /// 結果が前回から変わったときだけ呼ばれる（メインスレッド）。
    var onChange: (([DeviceBattery]) -> Void)?

    /// 概要の表示中だけ Bluetooth を定期的に調べる。
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive { startPolling() } else { stopPolling() }
        }
    }

    private static let pollInterval: TimeInterval = 30
    /// Wi-Fi の機器がこの時間読めなかったら「前回の値」として扱う。
    private static let wifiStaleAfter: TimeInterval = 90

    /// iPhone などの読み取りと Bluetooth の読み取りは、片方が詰まってももう片方が止まらないよう別のキューにする。
    private let mobileQueue = DispatchQueue(label: "DeviceBatteryMonitor.mobile", qos: .utility)
    private let bluetoothQueue = DispatchQueue(label: "DeviceBatteryMonitor.bluetooth", qos: .utility)
    private var mobile: MobileDeviceAPI?
    /// USB / Wi-Fi でつながっている機器（MobileDevice のポインタ。1 つずつ retain 済み）
    private var mobileDevices: [UnsafeMutableRawPointer] = []
    private var mobileResults: [UnsafeMutableRawPointer: DeviceBattery] = [:]
    /// 最後に読めた時刻（Wi-Fi で読めない状態が続いたかの判定用）
    private var lastRead: [UnsafeMutableRawPointer: Date] = [:]
    /// 読み取り中の機器。応答の遅い機器で読み取りが積み重ならないようにする。
    private var reading: Set<UnsafeMutableRawPointer> = []
    private var bluetoothResults: [DeviceBattery] = []
    private var published: [DeviceBattery] = []
    private var timer: Timer?
    private var bluetoothRunning = false
    private var subscribed = false

    private init() {}

    // MARK: - 定期更新

    private func startPolling() {
        subscribeMobileIfNeeded()
        refreshAll()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { _ in
            MainActor.assumeIsolated { DeviceBatteryMonitor.shared.refreshAll() }
        }
        // ウインドウのリサイズ中やスクロール中も止めない。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshAll() {
        for device in mobileDevices { readMobile(device) }
        refreshBluetooth()
    }

    private func publish() {
        // 同じ機器が USB と Wi-Fi の両方で届くことがあるので、USB を優先して 1 台にまとめる。
        var mobileByID: [String: DeviceBattery] = [:]
        for device in mobileResults.values {
            if let existing = mobileByID[device.id], existing.connection == "USB" { continue }
            mobileByID[device.id] = device
        }
        // Bluetooth も同じ id（同じ機器）が重なったら、今の値を優先する。
        var bluetoothByID: [String: DeviceBattery] = [:]
        for device in bluetoothResults {
            if let existing = bluetoothByID[device.id], !existing.isStale { continue }
            bluetoothByID[device.id] = device
        }
        let all = (Array(mobileByID.values) + Array(bluetoothByID.values))
            .map { device -> DeviceBattery in
                var device = device
                if Self.anonymizesNames {
                    // 機種名は本名を含まないので、分かればそれを使う。
                    device.name = device.model ?? device.kind.genericName
                    device.model = nil
                }
                return device
            }
            // 今の値を先に、そのうえで種類と名前で並べて、メーターの枠が入れ替わらないようにする。
            .sorted { ($0.isStale ? 1 : 0, $0.kind, $0.name, $0.id) < ($1.isStale ? 1 : 0, $1.kind, $1.name, $1.id) }
        guard all != published else { return }
        published = all
        onChange?(all)
    }

    // MARK: - iPhone / iPad（MobileDevice）

    private func subscribeMobileIfNeeded() {
        guard !subscribed else { return }
        subscribed = true
        guard let api = MobileDeviceAPI.load() else { return }
        mobile = api
        callbackAPI = api
        var notification: UnsafeMutableRawPointer?
        _ = api.subscribe(mobileNotificationCallback, 0, 0, nil, &notification)
    }

    /// 接続・切断の通知（message 1: 接続、2: 切断）。
    /// device は通知のコールバックの中で 1 つ retain 済み。ここで持ち続けるか解放する。
    fileprivate func handle(device: UnsafeMutableRawPointer, message: UInt32) {
        guard let api = mobile else { return }
        switch message {
        case 1:
            guard !mobileDevices.contains(device) else {
                api.release(device)
                return
            }
            mobileDevices.append(device)
            // 概要を見ていないときは読まない（表示したときにまとめて読む）。
            if isActive { readMobile(device) }
        case 2:
            api.release(device)
            guard let index = mobileDevices.firstIndex(of: device) else { return }
            mobileDevices.remove(at: index)
            mobileResults[device] = nil
            lastRead[device] = nil
            api.release(device)
            publish()
        default:
            api.release(device)
        }
    }

    private func readMobile(_ device: UnsafeMutableRawPointer) {
        guard let api = mobile, !reading.contains(device) else { return }
        reading.insert(device)
        // キューで使っている間に切断されても解放されないよう、もう 1 つ retain しておく。
        _ = api.retain(device)
        let address = UInt(bitPattern: device)
        mobileQueue.async {
            let pointer = UnsafeMutableRawPointer(bitPattern: address)!
            let result = api.readBattery(pointer)
            api.release(pointer)
            Task { @MainActor in
                let monitor = DeviceBatteryMonitor.shared
                monitor.reading.remove(pointer)
                // 読んでいる間に外された機器の結果は捨てる。
                guard monitor.mobileDevices.contains(pointer) else { return }
                if let result {
                    monitor.mobileResults[pointer] = result
                    monitor.lastRead[pointer] = Date()
                } else if var previous = monitor.mobileResults[pointer], previous.connection == "Wi-Fi" {
                    // Wi-Fi は端末のスリープ中などに一時的に読めないことがある。
                    // そのたびに消えるとちらつくので前回の値を残し、読めない状態が続いたら古い値と分かるようにする。
                    let last = monitor.lastRead[pointer] ?? .distantPast
                    if Date().timeIntervalSince(last) > Self.wifiStaleAfter {
                        previous.isStale = true
                        monitor.mobileResults[pointer] = previous
                    }
                } else {
                    monitor.mobileResults[pointer] = nil
                }
                monitor.publish()
            }
        }
    }

    // MARK: - Bluetooth（system_profiler）

    private func refreshBluetooth() {
        guard !bluetoothRunning else { return }
        bluetoothRunning = true
        bluetoothQueue.async {
            let devices = BluetoothBatteryReader.read()
            Task { @MainActor in
                let monitor = DeviceBatteryMonitor.shared
                monitor.bluetoothRunning = false
                if let devices { monitor.bluetoothResults = devices }
                monitor.publish()
            }
        }
    }
}

/// 通知のコールバックから使う関数一式（購読の前に一度だけ設定する）。
nonisolated(unsafe) private var callbackAPI: MobileDeviceAPI?

/// MobileDevice の通知。C の関数ポインタなので外の値は持ち込めず、共有インスタンスへ渡す。
///
/// 今はメインスレッドで届くが、非公開の仕組みなので将来変わっても落ちないようにする。
/// コールバックから戻ると device が解放されることがあるため、retain はここで同期的に行う。
private func mobileNotificationCallback(_ info: UnsafeMutableRawPointer?, _ context: UnsafeMutableRawPointer?) {
    guard let info, let api = callbackAPI else { return }
    // 構造体の先頭が機器のポインタ、その次が通知の種類（1: 接続 2: 切断）
    guard let device = info.load(as: UnsafeMutableRawPointer?.self) else { return }
    let message = info.load(fromByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
    _ = api.retain(device)
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            DeviceBatteryMonitor.shared.handle(device: device, message: message)
        }
    } else {
        let address = UInt(bitPattern: device)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                DeviceBatteryMonitor.shared.handle(device: UnsafeMutableRawPointer(bitPattern: address)!,
                                                   message: message)
            }
        }
    }
}

/// MobileDevice フレームワーク（非公開）の関数。実行時に探して使う。
private struct MobileDeviceAPI: @unchecked Sendable {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    typealias Subscribe = @convention(c) (Callback, UInt32, UInt32, UnsafeMutableRawPointer?,
                                          UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    typealias DeviceCall = @convention(c) (UnsafeMutableRawPointer) -> Int32
    typealias DeviceRelease = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias DeviceRetain = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    typealias CopyValue = @convention(c) (UnsafeMutableRawPointer, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
    typealias CopyIdentifier = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFString>?

    let subscribe: Subscribe
    let connect: DeviceCall
    let disconnect: DeviceCall
    let validatePairing: DeviceCall
    let startSession: DeviceCall
    let stopSession: DeviceCall
    let interfaceType: DeviceCall
    let retain: DeviceRetain
    let release: DeviceRelease
    let copyValue: CopyValue
    let copyIdentifier: CopyIdentifier

    static func load() -> MobileDeviceAPI? {
        let paths = ["/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
                     "/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"]
        guard let handle = paths.lazy.compactMap({ dlopen($0, RTLD_LAZY) }).first else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let subscribe = symbol("AMDeviceNotificationSubscribe", as: Subscribe.self),
              let connect = symbol("AMDeviceConnect", as: DeviceCall.self),
              let disconnect = symbol("AMDeviceDisconnect", as: DeviceCall.self),
              let validatePairing = symbol("AMDeviceValidatePairing", as: DeviceCall.self),
              let startSession = symbol("AMDeviceStartSession", as: DeviceCall.self),
              let stopSession = symbol("AMDeviceStopSession", as: DeviceCall.self),
              let interfaceType = symbol("AMDeviceGetInterfaceType", as: DeviceCall.self),
              let retain = symbol("AMDeviceRetain", as: DeviceRetain.self),
              let release = symbol("AMDeviceRelease", as: DeviceRelease.self),
              let copyValue = symbol("AMDeviceCopyValue", as: CopyValue.self),
              let copyIdentifier = symbol("AMDeviceCopyDeviceIdentifier", as: CopyIdentifier.self)
        else { return nil }
        return MobileDeviceAPI(subscribe: subscribe, connect: connect, disconnect: disconnect,
                               validatePairing: validatePairing, startSession: startSession,
                               stopSession: stopSession, interfaceType: interfaceType,
                               retain: retain, release: release, copyValue: copyValue,
                               copyIdentifier: copyIdentifier)
    }

    /// 機器に接続して残量を読む。ペアリング（「このコンピュータを信頼」）済みでなければ nil。
    /// iPhone 側に確認が出てしまうため、ペアリングの要求（AMDevicePair）はしない。
    func readBattery(_ device: UnsafeMutableRawPointer) -> DeviceBattery? {
        guard connect(device) == 0 else { return nil }
        defer { _ = disconnect(device) }
        guard validatePairing(device) == 0, startSession(device) == 0 else { return nil }
        defer { _ = stopSession(device) }

        let name = copyValue(device, nil, "DeviceName" as CFString)?.takeRetainedValue() as? String
        let model = copyValue(device, nil, "MarketingName" as CFString)?.takeRetainedValue() as? String
        let deviceClass = copyValue(device, nil, "DeviceClass" as CFString)?.takeRetainedValue() as? String
        guard let battery = copyValue(device, "com.apple.mobile.battery" as CFString, nil)?
                .takeRetainedValue() as? [String: Any],
              let capacity = battery["BatteryCurrentCapacity"] as? Int else { return nil }
        // 識別子が取れないときは、毎回変わる値にせず機器のポインタで代用する（同じ接続の間は変わらない）。
        let identifier = copyIdentifier(device)?.takeRetainedValue() as String?
            ?? "pointer-\(UInt(bitPattern: device))"

        let kind: DeviceBattery.Kind
        switch deviceClass {
        case "iPhone": kind = .iPhone
        case "iPad": kind = .iPad
        case "iPod": kind = .iPod
        default: kind = .other
        }
        return DeviceBattery(id: "mobile-" + identifier,
                             name: name ?? model ?? kind.genericName,
                             model: model,
                             kind: kind,
                             level: min(1, max(0, Double(capacity) / 100)),
                             isCharging: (battery["BatteryIsCharging"] as? Bool) ?? false,
                             connection: interfaceType(device) == 1 ? "USB" : "Wi-Fi")
    }
}

/// Bluetooth 機器の残量を system_profiler から読む（1 回 0.2 秒ほど）。
private enum BluetoothBatteryReader {
    /// 読めなかったときは nil（前回の結果を残す）。
    static func read() -> [DeviceBattery]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "-detailLevel", "basic", "SPBluetoothDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // bluetoothd が応答しないなどで止まったときに備え、10 秒で打ち切る。
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }

        var devices: [DeviceBattery] = []
        for section in sections {
            // 未接続の機器にも、最後に接続していたときの残量が残っていることがある。
            // 古い値だと分かるよう「前回の値」として出す。
            for (key, stale) in [("device_connected", false), ("device_not_connected", true)] {
                guard let entries = section[key] as? [[String: Any]] else { continue }
                for entry in entries {
                    for (name, value) in entry {
                        guard let properties = value as? [String: Any],
                              let device = makeDevice(name: name, properties: properties, stale: stale)
                        else { continue }
                        devices.append(device)
                    }
                }
            }
        }
        return devices
    }

    private static func makeDevice(name: String, properties: [String: Any], stale: Bool) -> DeviceBattery? {
        func percent(_ key: String) -> Double? {
            guard let text = properties[key] as? String else { return nil }
            return Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))).map { $0 / 100 }
        }
        let main = percent("device_batteryLevelMain") ?? percent("device_batteryLevel")
        let left = percent("device_batteryLevelLeft")
        let right = percent("device_batteryLevelRight")
        let caseLevel = percent("device_batteryLevelCase")
        // 左右があれば少ないほうを代表値にする（先に切れるほう）。
        guard let level = main ?? [left, right].compactMap({ $0 }).min() ?? caseLevel else { return nil }

        var parts: [String] = []
        if let left { parts.append(String(format: "左 %.0f%%", left * 100)) }
        if let right { parts.append(String(format: "右 %.0f%%", right * 100)) }
        if let caseLevel { parts.append(String(format: "ケース %.0f%%", caseLevel * 100)) }

        let kind: DeviceBattery.Kind
        switch (properties["device_minorType"] as? String ?? "").lowercased() {
        case let type where type.contains("headphone") || type.contains("headset"): kind = .headphones
        case let type where type.contains("keyboard"): kind = .keyboard
        case let type where type.contains("mouse"): kind = .mouse
        case let type where type.contains("trackpad"): kind = .trackpad
        default: kind = .other
        }
        let address = properties["device_address"] as? String ?? name
        return DeviceBattery(id: "bt-" + address, name: name, kind: kind,
                             level: min(1, max(0, level)), isCharging: false,
                             connection: "Bluetooth", isStale: stale,
                             detail: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }
}
