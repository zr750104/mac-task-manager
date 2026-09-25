import Foundation
import WidgetKit

/// ウィジェットの更新間隔。
enum WidgetRefreshInterval: Double, CaseIterable, Identifiable {
    case fast = 5
    case normal = 10
    case slow = 30
    case minute = 60

    var id: Double { rawValue }
    var label: String { "\(Int(rawValue)) 秒" }
}

/// アプリ本体からウィジェットの更新を依頼する。
///
/// ウィジェット自身の「1 分後に更新して」という依頼は、macOS が
/// 「1 分後〜15 分後のどこか」という幅で受け付け、1 日の回数にも上限（予算）がある。
/// 一方、ウィジェットを持つアプリ本体からの依頼は予算の対象外で、即座に反映される
/// （chronod のログで `budget exempt reason: containerApp` を確認済み）。
/// メニューバーに常駐しているアプリから一定間隔で依頼することで、数秒おきに更新できる。
///
/// 負荷は 15 秒間隔で chronod とウィジェットを合わせて 1 コアの約 0.5%。
@MainActor
enum WidgetRefresher {
    nonisolated static let kind = "SystemStats"
    private static var timer: Timer?

    static func start(interval: WidgetRefreshInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval.rawValue, repeats: true) { _ in
            refreshIfPlaced()
        }
        timer?.tolerance = interval.rawValue * 0.1
    }

    /// ウィジェットが置かれているときだけ更新を依頼する。
    /// 置かれていないのに依頼すると、ウィジェットのプロセスを無駄に起こしてしまう。
    /// （macOS 14 でも使えるよう、async 版ではなく完了ハンドラ版を使う）
    private nonisolated static func refreshIfPlaced() {
        WidgetCenter.shared.getCurrentConfigurations { result in
            guard case .success(let configurations) = result,
                  configurations.contains(where: { $0.kind == kind }) else { return }
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }
}
