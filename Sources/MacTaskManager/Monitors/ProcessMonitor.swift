import Foundation
import Darwin

struct ProcessRow: Sendable, Identifiable, Hashable {
    var id: pid_t { pid }
    var pid: pid_t
    var ppid: pid_t
    /// 表示名（GUI アプリなら後段でローカライズ名に差し替える）
    var name: String
    var executablePath: String
    var user: String
    var uid: uid_t
    /// 100% = 1 コアを占有
    var cpuPercent: Double
    /// 物理フットプリント（取得できなければ RSS）
    var memory: UInt64
    var threads: Int
    /// 累積 CPU 時間（秒）
    var cpuTime: Double
    /// ディスク読み書きの累積バイト数
    var diskRead: UInt64 = 0
    var diskWrite: UInt64 = 0
    /// 直近の読み書き速度（バイト/秒）
    var diskReadRate: Double = 0
    var diskWriteRate: Double = 0
    var startTime: Date
    /// Rosetta 2 経由で動く x86_64 プロセス
    var isTranslated: Bool
    var isOwnedByCurrentUser: Bool
    /// libproc で直接測れたか（false なら setuid された ps 経由）
    var isPrecise: Bool
    var isGUIApp: Bool = false
    var bundleIdentifier: String?

    /// 所属するアプリの .app のパス。
    /// ヘルパープロセスは親アプリの .app の中に入っているので、
    /// 最初に現れる .app をたどると親アプリに行き着く。
    var appBundlePath: String? {
        guard let range = executablePath.range(of: ".app/") else { return nil }
        return String(executablePath[..<range.lowerBound]) + ".app"
    }

    /// 所属アプリの表示名。アプリとして識別できなければプロセス名。
    var appDisplayName: String {
        guard let bundle = appBundlePath else { return name }
        return String((bundle as NSString).lastPathComponent.dropLast(4))
    }
}

/// プロセス一覧。
///
/// 1) sysctl KERN_PROC_ALL で全プロセスの基本情報（権限不要）
/// 2) libproc で自ユーザーのプロセスの CPU 時間・メモリを取得
/// 3) 権限が無いプロセスは setuid root の /bin/ps から借りる
///
/// CPU 時間の取り方には注意が必要で、`PROC_PIDTASKINFO` や `proc_pid_rusage` が返す値は
/// **終了済みスレッドの分しか含まない**（実測で top と大きく食い違うことを確認済み）。
/// そのため「タスク累積 + 実行中スレッドの合計」で算出している。
final class ProcessMonitor {
    /// 前回サンプルの情報。差分計算と、変化しない値のキャッシュを兼ねる。
    private struct Cache {
        var cpuTime: Double
        var timestamp: Date
        /// PID 再利用を検出するために開始時刻も持つ。
        var startTime: Date
        var executablePath: String
        var diskRead: UInt64
        var diskWrite: UInt64
    }

    private var cache: [pid_t: Cache] = [:]
    private var userNameCache: [uid_t: String] = [:]
    private let currentUID = getuid()

    /// P_TRANSLATED: Rosetta 変換プロセスを示す proc フラグ。
    private static let P_TRANSLATED: Int32 = 0x0002_0000

    func sample() -> [ProcessRow] {
        let now = Date()
        let kinfos = allProcesses()
        guard !kinfos.isEmpty else { return [] }

        var needsFallback = false
        var rows: [ProcessRow] = []
        rows.reserveCapacity(kinfos.count)

        for info in kinfos {
            let pid = info.kp_proc.p_pid
            guard pid > 0 else { continue }

            let uid = info.kp_eproc.e_ucred.cr_uid
            // C 側では p_starttime マクロ経由だが、Swift には共用体の実体名で入る。
            let started = info.kp_proc.p_un.__p_starttime
            let start = Date(timeIntervalSince1970:
                Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)

            // 同じ PID でも開始時刻が違えば別プロセス（PID 再利用）なのでキャッシュを捨てる。
            let cached = cache[pid].flatMap {
                abs($0.startTime.timeIntervalSince(start)) < 1 ? $0 : nil
            }

            var row = ProcessRow(
                pid: pid,
                ppid: info.kp_eproc.e_ppid,
                name: shortName(from: info),
                executablePath: cached?.executablePath ?? "",
                user: userName(for: uid),
                uid: uid,
                cpuPercent: 0,
                memory: 0,
                threads: 0,
                cpuTime: 0,
                startTime: start,
                isTranslated: (info.kp_proc.p_flag & Self.P_TRANSLATED) != 0,
                isOwnedByCurrentUser: uid == currentUID,
                isPrecise: false
            )

            // --- libproc ---
            var task = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size {
                row.threads = Int(task.pti_threadnum)
                row.memory = UInt64(task.pti_resident_size)
                row.isPrecise = true

                // 終了済みスレッド分 + 実行中スレッド分。
                let terminated = Double(task.pti_total_user + task.pti_total_system) / 1_000_000_000
                row.cpuTime = terminated + liveThreadCPUTime(pid: pid, threadCount: Int(task.pti_threadnum))

                // メモリはフットプリントのほうが Activity Monitor の表示に近い。
                // ディスク I/O の累積値も同じ rusage から取れる。
                if let usage = resourceUsage(pid: pid) {
                    if usage.ri_phys_footprint > 0 { row.memory = usage.ri_phys_footprint }
                    row.diskRead = usage.ri_diskio_bytesread
                    row.diskWrite = usage.ri_diskio_byteswritten
                }
            } else {
                needsFallback = true
            }

            // 実行ファイルのパスは変わらないので初回だけ引く（1 サンプルあたり数 ms 節約）。
            if row.executablePath.isEmpty, let path = executablePath(pid: pid) {
                row.executablePath = path
            }
            if !row.executablePath.isEmpty {
                row.name = Self.preferredName(shortName: row.name, path: row.executablePath)
            }
            rows.append(row)
        }

        // --- ps フォールバック（libproc が拒否されたプロセス） ---
        // /bin/ps は setuid root なので root 所有プロセスの値も正確に取れる。
        // ただし %cpu は生涯平均で現在の負荷を表さないため、累積 CPU 時間 (time=) だけを借りて
        // 自前で差分を取る。初回サンプルのときだけ %cpu を暫定値として使う。
        if needsFallback {
            let fallback = psSnapshot()
            for index in rows.indices where !rows[index].isPrecise {
                guard let entry = fallback[rows[index].pid] else { continue }
                rows[index].memory = entry.rss
                rows[index].cpuTime = entry.cpuTime
                if rows[index].executablePath.isEmpty {
                    rows[index].executablePath = entry.command
                    rows[index].name = Self.preferredName(shortName: rows[index].name, path: entry.command)
                }
                if cache[rows[index].pid] == nil { rows[index].cpuPercent = entry.cpu }
            }
        }

        // --- 累積 CPU 時間の差分から使用率を求める（libproc / ps 共通） ---
        var updated: [pid_t: Cache] = [:]
        updated.reserveCapacity(rows.count)
        for index in rows.indices {
            let row = rows[index]
            updated[row.pid] = Cache(cpuTime: row.cpuTime, timestamp: now,
                                     startTime: row.startTime, executablePath: row.executablePath,
                                     diskRead: row.diskRead, diskWrite: row.diskWrite)

            if let prev = cache[row.pid], abs(prev.startTime.timeIntervalSince(row.startTime)) < 1 {
                let dt = now.timeIntervalSince(prev.timestamp)
                if dt > 0.05 {
                    rows[index].cpuPercent = max(0, (row.cpuTime - prev.cpuTime) / dt * 100)
                    if row.diskRead >= prev.diskRead {
                        rows[index].diskReadRate = Double(row.diskRead - prev.diskRead) / dt
                    }
                    if row.diskWrite >= prev.diskWrite {
                        rows[index].diskWriteRate = Double(row.diskWrite - prev.diskWrite) / dt
                    }
                }
            } else if row.isPrecise {
                // 初回は起動からの平均を暫定値にする。
                let elapsed = now.timeIntervalSince(row.startTime)
                if elapsed > 1 { rows[index].cpuPercent = min(100, row.cpuTime / elapsed * 100) }
            }
        }

        cache = updated
        return rows
    }

    // MARK: - 情報源

    /// sysctl KERN_PROC_ALL。全プロセスの基本情報を権限なしで一括取得する。
    private func allProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // 取得の合間にプロセスが増えることがあるので余裕を持たせる。
        size += MemoryLayout<kinfo_proc>.stride * 32
        let count = size / MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [] }
        return Array(buffer.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    /// 実行中スレッドの CPU 時間の合計（秒）。
    private func liveThreadCPUTime(pid: pid_t, threadCount: Int) -> Double {
        guard threadCount > 0 else { return 0 }
        var ids = [UInt64](repeating: 0, count: threadCount + 16)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, &ids,
                                 Int32(ids.count * MemoryLayout<UInt64>.size))
        guard bytes > 0 else { return 0 }

        var total: Double = 0
        let size = Int32(MemoryLayout<proc_threadinfo>.size)
        for index in 0..<(Int(bytes) / MemoryLayout<UInt64>.size) {
            var thread = proc_threadinfo()
            if proc_pidinfo(pid, PROC_PIDTHREADINFO, ids[index], &thread, size) == size {
                total += Double(thread.pth_user_time + thread.pth_system_time) / 1_000_000_000
            }
        }
        return total
    }

    private func shortName(from info: kinfo_proc) -> String {
        var comm = info.kp_proc.p_comm
        return withUnsafeBytes(of: &comm) { raw in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: Array(bytes) + [0])
        }
    }

    /// p_comm は 16 バイトで切り詰められるので、実行ファイル名で復元できるなら差し替える。
    private static func preferredName(shortName: String, path: String) -> String {
        guard let base = path.split(separator: "/").last.map(String.init), !base.isEmpty else { return shortName }
        // 切り詰められた名前の続きである場合のみ採用し、別名への置き換えは避ける。
        return base.count > shortName.count && base.hasPrefix(shortName) ? base : shortName
    }

    private func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// 物理フットプリントとディスク I/O の累積値。
    private func resourceUsage(pid: pid_t) -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return usage
    }

    private func userName(for uid: uid_t) -> String {
        if let cached = userNameCache[uid] { return cached }
        var name = "\(uid)"
        if let pw = getpwuid(uid), let raw = pw.pointee.pw_name {
            name = String(cString: raw)
        }
        userNameCache[uid] = name
        return name
    }

    private struct PSEntry {
        var cpu: Double
        var rss: UInt64
        var cpuTime: Double
        var command: String
    }

    /// 権限の無いプロセス用に ps の出力を借りる。
    private func psSnapshot() -> [pid_t: PSEntry] {
        // Foundation の Process は 1 回あたり約 95ms かかり毎秒の更新には重すぎるため、
        // posix_spawn を直接使う（実測で約 25ms まで短縮）。
        guard let text = Self.runCapturingOutput(
            path: "/bin/ps",
            arguments: ["ps", "-Ao", "pid=,%cpu=,rss=,time=,comm="]) else { return [:] }

        var result: [pid_t: PSEntry] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count >= 5,
                  let pid = pid_t(fields[0]),
                  let cpu = Double(fields[1]),
                  let rssKB = UInt64(fields[2]) else { continue }
            result[pid] = PSEntry(cpu: cpu,
                                  rss: rssKB * 1024,
                                  cpuTime: Self.parsePSTime(String(fields[3])),
                                  command: String(fields[4]))
        }
        return result
    }

    /// 外部コマンドを実行し、標準出力を文字列で受け取る。
    /// arguments の先頭は argv[0]（コマンド名）。
    private static func runCapturingOutput(path: String, arguments: [String]) -> String? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let readEnd = fds[0], writeEnd = fds[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
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
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
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

    /// ps の TIME 列（"12:34.56" / "1:02:03.45"）を秒に変換する。
    private static func parsePSTime(_ text: String) -> Double {
        let parts = text.split(separator: ":").map { Double($0) ?? 0 }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
        }
    }

    // MARK: - 操作

    enum TerminationResult {
        case success
        case permissionDenied
        case notFound
        case failed(Int32)
    }

    /// プロセスへシグナルを送る。SIGTERM = 終了、SIGKILL = 強制終了。
    static func terminate(pid: pid_t, force: Bool) -> TerminationResult {
        guard pid > 0 else { return .notFound }
        if kill(pid, force ? SIGKILL : SIGTERM) == 0 { return .success }
        switch errno {
        case EPERM: return .permissionDenied
        case ESRCH: return .notFound
        default: return .failed(errno)
        }
    }
}

/// アプリ単位でまとめたメモリ使用量。
struct AppMemoryUsage: Sendable, Identifiable {
    var id: String { name }
    var name: String
    var memory: UInt64
    /// まとめられたプロセスの数（ヘルパーを含む）
    var processCount: Int
    /// .app として識別できたか（できなければシステムのサービス）
    var isApp: Bool
    /// アイコンを読み込むための .app のパス。サービスの場合は nil。
    var bundlePath: String?
    var isOwnedByCurrentUser: Bool
}
