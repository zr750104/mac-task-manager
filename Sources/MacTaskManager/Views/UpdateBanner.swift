import SwiftUI

/// 新しいバージョンが見つかったときに画面上部へ出す帯。
/// 自動更新はせず、リリースページを開くところまでを担当する。
struct UpdateBanner: View {
    @EnvironmentObject private var updates: UpdateChecker
    @State private var isShowingNotes = false

    var body: some View {
        if case .available(let release) = updates.state {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Palette.cpu)

                VStack(alignment: .leading, spacing: 1) {
                    Text("新しいバージョン \(release.version) が公開されています")
                        .font(.callout.weight(.medium))
                    Text("現在のバージョンは \(updates.currentVersion) です"
                         + (release.notes.isEmpty ? "" : " · 変更点を見るには「詳細」をどうぞ"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if !release.notes.isEmpty {
                    Button("詳細") { isShowingNotes = true }
                        .buttonStyle(.borderless)
                }
                Button("ダウンロード") { updates.openReleasePage(release) }
                    .buttonStyle(.borderedProminent)
                Button {
                    updates.skip(release)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("このバージョンの通知を今後表示しない")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.cpu.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.cpu.opacity(0.35)))
            .sheet(isPresented: $isShowingNotes) {
                notesSheet(release)
            }
        }
    }

    private func notesSheet(_ release: UpdateChecker.Release) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(release.name)
                .font(.title3.weight(.semibold))
            if let published = release.publishedAt {
                Text(published.formatted(date: .long, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(release.notes)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("閉じる") { isShowingNotes = false }
                Button("ダウンロード") {
                    updates.openReleasePage(release)
                    isShowingNotes = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 520, height: 400)
    }
}

/// 「アップデートを確認」を押したときの結果表示。
struct UpdateStatusView: View {
    @EnvironmentObject private var updates: UpdateChecker

    var body: some View {
        switch updates.state {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("確認中…").font(.caption).foregroundStyle(.secondary)
            }
        case .upToDate:
            Text("最新版です（\(updates.currentVersion)）")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let reason):
            // ツールバーは幅が限られていてラベルが省略されるため、
            // 理由はツールチップでも読めるようにしておく。
            Label("更新を確認できません", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(reason)
        case .idle, .available:
            EmptyView()
        }
    }
}
