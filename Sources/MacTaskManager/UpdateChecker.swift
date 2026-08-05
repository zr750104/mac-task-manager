import Foundation
import AppKit

/// GitHub Releases を見て新しいバージョンがあるか調べる。
///
/// このアプリは Apple の開発者証明書で署名していない（ad-hoc 署名）ため、
/// ダウンロードして自動で入れ替えると Gatekeeper に阻まれたり、
/// 差し替え自体が改ざんの経路になりかねない。
/// そこで **通知とリリースページを開くところまで**にとどめ、
/// 実際の更新はユーザーの操作に任せている。
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// 公開先のリポジトリ。フォークした場合はここだけ書き換える。
    static let repository = "zr750104/mac-task-manager"

    struct Release: Sendable, Equatable {
        var version: String
        var name: String
        var notes: String
        var pageURL: URL
        var publishedAt: Date?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(checkedAt: Date)
        case available(Release)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Info.plist の CFBundleShortVersionString
    let currentVersion: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }()

    private let defaults = UserDefaults.standard
    private let lastCheckKey = "lastUpdateCheck"
    private let skippedVersionKey = "skippedUpdateVersion"
    private let automaticKey = "checksForUpdatesAutomatically"

    var checksAutomatically: Bool {
        get { defaults.object(forKey: automaticKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: automaticKey) }
    }

    private init() {
        defaults.register(defaults: [automaticKey: true])
    }

    /// 起動時に呼ぶ。前回の確認から 24 時間経っていれば静かに調べる。
    func checkOnLaunchIfNeeded() {
        guard checksAutomatically else { return }
        let last = defaults.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 60 * 60 * 24 else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        if case .checking = state { return }
        state = .checking
        defaults.set(Date(), forKey: lastCheckKey)

        do {
            let release = try await fetchLatestRelease()
            // 自分から確認したときは、以前スキップしたものでも知らせる。
            let skipped = defaults.string(forKey: skippedVersionKey)
            if !userInitiated, skipped == release.version {
                state = .upToDate(checkedAt: Date())
                return
            }
            if Self.isNewer(release.version, than: currentVersion) {
                state = .available(release)
            } else {
                state = .upToDate(checkedAt: Date())
            }
        } catch {
            // 起動時の自動確認は、通信できなくても黙って諦める。
            // 自分で「確認」を押したときだけ理由を見せる。
            state = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    func skip(_ release: Release) {
        defaults.set(release.version, forKey: skippedVersionKey)
        state = .upToDate(checkedAt: Date())
    }

    func openReleasePage(_ release: Release) {
        NSWorkspace.shared.open(release.pageURL)
    }

    var releasesPageURL: URL {
        URL(string: "https://github.com/\(Self.repository)/releases")!
    }

    // MARK: - 取得

    private func fetchLatestRelease() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure("応答を解釈できませんでした。")
        }
        if http.statusCode == 404 {
            throw Failure("リリースがまだ公開されていません。")
        }
        guard http.statusCode == 200 else {
            throw Failure("GitHub から HTTP \(http.statusCode) が返りました。")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = json["html_url"] as? String,
              let pageURL = URL(string: page) else {
            throw Failure("リリース情報の形式が想定と違います。")
        }
        var published: Date?
        if let text = json["published_at"] as? String {
            published = ISO8601DateFormatter().date(from: text)
        }
        return Release(version: Self.normalize(tag),
                       name: (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag,
                       notes: (json["body"] as? String) ?? "",
                       pageURL: pageURL,
                       publishedAt: published)
    }

    private struct Failure: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }

    // MARK: - バージョン比較

    /// "v1.2.3" → "1.2.3"
    static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// 数値ごとに比較する。"1.10.0" > "1.9.0" を正しく判定するため文字列比較はしない。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = normalize(candidate).split(separator: ".").map { Int($0) ?? 0 }
        let b = normalize(current).split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
