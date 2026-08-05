import Foundation

enum StartupScope: Int, Sendable, CaseIterable, Comparable {
    case userAgent
    case systemAgent
    case systemDaemon

    var label: String {
        switch self {
        case .userAgent: return "ユーザーのログイン項目"
        case .systemAgent: return "全ユーザー共通のログイン項目"
        case .systemDaemon: return "システムデーモン"
        }
    }

    var note: String {
        switch self {
        case .userAgent: return "自分のログイン時に起動します。有効・無効を切り替えられます。"
        case .systemAgent: return "全ユーザー共通の設定です。変更には管理者権限が必要なため表示のみです。"
        case .systemDaemon: return "OS 起動時に動くサービスです。変更には管理者権限が必要なため表示のみです。"
        }
    }

    /// 管理者権限なしで有効・無効を切り替えられるか。
    var isEditable: Bool { self == .userAgent }

    var directory: String {
        switch self {
        case .userAgent:
            return (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents")
        case .systemAgent: return "/Library/LaunchAgents"
        case .systemDaemon: return "/Library/LaunchDaemons"
        }
    }

    static func < (lhs: StartupScope, rhs: StartupScope) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct StartupItem: Sendable, Identifiable, Hashable {
    var id: String { label + path }
    /// launchd のラベル（com.example.agent）
    var label: String
    /// plist のパス
    var path: String
    /// 実行されるコマンド
    var program: String
    var scope: StartupScope
    /// ログイン時に自動起動する設定か
    var runAtLoad: Bool
    /// launchctl 上で無効化されているか
    var isDisabled: Bool
    /// 現在動いていれば PID
    var pid: pid_t?
    /// 最後の終了コード（0 以外は異常終了）
    var lastExitStatus: Int?

    var isRunning: Bool { pid != nil }

    /// アプリ名らしき表示名（com.google.keystone.agent → keystone.agent）
    var displayName: String {
        let parts = label.split(separator: ".")
        guard parts.count > 2 else { return label }
        return parts.dropFirst(2).joined(separator: ".")
    }

    /// 提供元らしき文字列（com.google.… → google）
    var vendor: String {
        let parts = label.split(separator: ".")
        return parts.count >= 2 ? String(parts[1]) : ""
    }
}

struct StartupSample: Sendable {
    var items: [StartupItem] = []

    func items(in scope: StartupScope) -> [StartupItem] {
        items.filter { $0.scope == scope }.sorted { $0.label < $1.label }
    }

    var scopes: [StartupScope] {
        Array(Set(items.map(\.scope))).sorted()
    }
}

/// ログイン項目・常駐エージェントの一覧。
/// LaunchAgents / LaunchDaemons の plist を読み、`launchctl` で現在の状態を補う。
/// 参照はすべて管理者権限なしで行える。
final class StartupMonitor {

    func sample() -> StartupSample {
        let running = runningServices()
        let disabled = disabledServices()

        var items: [StartupItem] = []
        for scope in StartupScope.allCases {
            let directory = scope.directory
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                continue
            }
            for name in names where name.hasSuffix(".plist") {
                let path = (directory as NSString).appendingPathComponent(name)
                guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }

                let label = (plist["Label"] as? String)
                    ?? (name as NSString).deletingPathExtension
                var program = plist["Program"] as? String ?? ""
                if program.isEmpty, let arguments = plist["ProgramArguments"] as? [String] {
                    program = arguments.joined(separator: " ")
                }

                let state = running[label]
                items.append(StartupItem(
                    label: label,
                    path: path,
                    program: program,
                    scope: scope,
                    runAtLoad: (plist["RunAtLoad"] as? Bool) ?? false,
                    // plist 内の Disabled より launchctl の状態を優先する。
                    isDisabled: disabled[label] ?? (plist["Disabled"] as? Bool) ?? false,
                    pid: state?.pid,
                    lastExitStatus: state?.status
                ))
            }
        }
        return StartupSample(items: items)
    }

    // MARK: - launchctl

    /// `launchctl list` から PID と最終終了コードを取る。
    private func runningServices() -> [String: (pid: pid_t?, status: Int?)] {
        guard let output = Self.run("/bin/launchctl", ["launchctl", "list"]) else { return [:] }
        var result: [String: (pid: pid_t?, status: Int?)] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let label = String(fields[2])
            result[label] = (pid: pid_t(fields[0]), status: Int(fields[1]))
        }
        return result
    }

    /// `launchctl print-disabled` から無効化されているラベルを取る（sudo 不要）。
    private func disabledServices() -> [String: Bool] {
        let domain = "gui/\(getuid())"
        guard let output = Self.run("/bin/launchctl", ["launchctl", "print-disabled", domain]) else {
            return [:]
        }
        var result: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            // 	"com.example.agent" => disabled
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let arrow = trimmed.range(of: "=>") else { continue }
            let label = trimmed[trimmed.index(after: trimmed.startIndex)..<trimmed.index(before: arrow.lowerBound)]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            let value = trimmed[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            result[label] = value.hasPrefix("disabled")
        }
        return result
    }

    /// ユーザー領域のエージェントを有効・無効にする。管理者権限は不要。
    /// 成功したら nil、失敗したらエラーメッセージを返す。
    static func setEnabled(_ enabled: Bool, item: StartupItem) -> String? {
        guard item.scope.isEditable else {
            return "「\(item.label)」は全ユーザー共通の設定のため、このアプリからは変更できません。"
        }
        let domain = "gui/\(getuid())"
        let action = enabled ? "enable" : "disable"
        guard let output = run("/bin/launchctl", ["launchctl", action, "\(domain)/\(item.label)"],
                               captureError: true) else {
            return "launchctl を実行できませんでした。"
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else {
            return "launchctl が次のエラーを返しました:\n\(trimmed)"
        }
        // 無効化しただけでは動作中のプロセスは止まらないので、明示的に停止する。
        if !enabled {
            _ = run("/bin/launchctl", ["launchctl", "bootout", "\(domain)/\(item.label)"],
                    captureError: true)
        } else {
            _ = run("/bin/launchctl", ["launchctl", "bootstrap", domain, item.path],
                    captureError: true)
        }
        return nil
    }

    /// 外部コマンドを実行して標準出力（必要なら標準エラーも）を返す。
    @discardableResult
    private static func run(_ path: String, _ arguments: [String],
                            captureError: Bool = false) -> String? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let readEnd = fds[0], writeEnd = fds[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, STDOUT_FILENO)
        if captureError {
            posix_spawn_file_actions_adddup2(&actions, writeEnd, STDERR_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_addclose(&actions, readEnd)
        defer { posix_spawn_file_actions_destroy(&actions) }

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv where pointer != nil { free(pointer) } }

        var child: pid_t = 0
        let status = posix_spawn(&child, path, &actions, nil, &argv, environ)
        close(writeEnd)
        guard status == 0 else {
            close(readEnd)
            return nil
        }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = read(readEnd, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer[0..<count])
            } else if count == 0 || errno != EINTR {
                break
            }
        }
        close(readEnd)
        var exitStatus: Int32 = 0
        waitpid(child, &exitStatus, 0)
        return String(data: output, encoding: .utf8)
    }
}
