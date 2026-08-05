import Foundation

/// メモリの解放（ディスクキャッシュの破棄）を行う。
///
/// macOS の `/usr/sbin/purge` は setuid されておらず、実行には root 権限が要る
/// （権限なしで実行すると `Unable to purge disk buffers: Operation not permitted` になる）。
/// そのため管理者パスワードの入力ダイアログを出して実行する。
/// パスワードは macOS の認証ダイアログが受け取るので、このアプリが触ることはない。
enum MemoryReclaimer {

    enum Result: Sendable {
        case success
        case cancelled
        case failed(String)
    }

    /// `purge` が使えるかどうか。
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/sbin/purge")
    }

    /// 管理者権限を求めて `purge` を実行する。時間がかかるのでバックグラウンドで走らせる。
    static func purge() async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runWithAdministratorPrivileges())
            }
        }
    }

    private static func runWithAdministratorPrivileges() -> Result {
        // AppleScript 経由だと macOS 標準の認証ダイアログが出る。
        let script = """
        do shell script "/usr/sbin/purge" with administrator privileges
        """
        var error: NSDictionary?
        guard let apple = NSAppleScript(source: script) else {
            return .failed("スクリプトを準備できませんでした。")
        }
        apple.executeAndReturnError(&error)

        guard let error else { return .success }
        // -128 はユーザーがキャンセルしたとき。
        if let code = error[NSAppleScript.errorNumber] as? Int, code == -128 {
            return .cancelled
        }
        let message = error[NSAppleScript.errorMessage] as? String ?? "不明なエラー"
        return .failed(message)
    }
}
