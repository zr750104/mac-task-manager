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

    /// NSAppleScript はメインスレッド以外での利用が保証されていないため、
    /// osascript を別プロセスで起動して待つ。認証ダイアログは osascript 側に出る。
    private static func runWithAdministratorPrivileges() -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failed("osascript を起動できませんでした: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        if process.terminationStatus == 0 { return .success }

        let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // -128 はユーザーが認証ダイアログでキャンセルしたとき。
        if message.contains("-128") { return .cancelled }
        return .failed(message.isEmpty ? "不明なエラー（終了コード \(process.terminationStatus)）" : message)
    }
}
