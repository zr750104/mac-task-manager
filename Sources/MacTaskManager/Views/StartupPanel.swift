import SwiftUI
import AppKit
import ServiceManagement

struct StartupPanel: View {
    @EnvironmentObject private var engine: MetricsEngine

    @State private var message: String?
    @State private var pendingToggle: (item: StartupItem, enable: Bool)?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        let startup = engine.startup

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: "起動項目",
                            subtitle: "ログイン時・OS 起動時に自動で動くプログラム",
                            value: "\(startup.items.count)",
                            valueColor: .primary)

                TileGrid(items: [
                    .init("登録数", "\(startup.items.count) 件",
                          caption: "ユーザー \(startup.items(in: .userAgent).count) / 共通 \(startup.items(in: .systemAgent).count) / システム \(startup.items(in: .systemDaemon).count)"),
                    .init("実行中", "\(startup.items.filter(\.isRunning).count) 件",
                          caption: "現在プロセスが存在するもの", color: Palette.disk),
                    .init("無効", "\(startup.items.filter(\.isDisabled).count) 件",
                          caption: "launchctl で無効化されているもの", color: .secondary)
                ])

                selfLaunchToggle

                ForEach(startup.scopes, id: \.rawValue) { scope in
                    section(scope, items: startup.items(in: scope))
                }

                Text("この一覧は LaunchAgents / LaunchDaemons の設定ファイルを読んで作っています。macOS のシステム設定にある「ログイン時に開く」のアプリ一覧は OS 内部のデータベースで管理されており、管理者権限なしでは読み出せないため含まれません。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("起動項目を変更できません", isPresented: .constant(message != nil)) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .confirmationDialog(pendingToggle?.enable == true ? "有効にしますか？" : "無効にしますか？",
                            isPresented: .constant(pendingToggle != nil)) {
            if let pending = pendingToggle {
                Button(pending.enable ? "有効にする" : "無効にする",
                       role: pending.enable ? nil : .destructive) {
                    apply(pending)
                    pendingToggle = nil
                }
            }
            Button("キャンセル", role: .cancel) { pendingToggle = nil }
        } message: {
            if let pending = pendingToggle {
                Text(pending.enable
                     ? "「\(pending.item.label)」を次回ログインから起動するようにします。"
                     : "「\(pending.item.label)」を起動しないようにし、動作中であれば停止します。\nそのソフトの自動更新や常駐機能が止まる場合があります。")
            }
        }
    }

    /// このアプリ自身をログイン時に起動するかどうか。
    private var selfLaunchToggle: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("このアプリをログイン時に起動")
                    .font(.callout.weight(.medium))
                Text("ログインすると自動でタスクマネージャーが立ち上がります。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    } catch {
                        message = "設定を変更できませんでした: \(error.localizedDescription)"
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
    }

    private func section(_ scope: StartupScope, items: [StartupItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(scope.label).font(.headline)
                Text("\(items.count) 件").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if !scope.isEditable {
                    Label("表示のみ", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(scope.note)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            VStack(spacing: 0) {
                ForEach(items) { item in
                    row(item)
                    if item.id != items.last?.id { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
        }
    }

    private func row(_ item: StartupItem) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(item.isDisabled ? Color.secondary.opacity(0.4)
                      : (item.isRunning ? Palette.disk : Palette.gpu))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if item.isDisabled {
                        Text("無効")
                            .font(.caption2)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3)
                                .fill(Color.secondary.opacity(0.25)))
                    }
                    if item.runAtLoad && !item.isDisabled {
                        Text("ログイン時に起動")
                            .font(.caption2)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3)
                                .fill(Palette.cpu.opacity(0.22)))
                    }
                }
                Text(item.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.program.isEmpty ? item.path : item.program)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                if let pid = item.pid {
                    // 桁区切りが入らないよう String 化してから埋め込む。
                    Text("PID \(String(pid))").font(.caption2).monospacedDigit()
                        .foregroundStyle(Palette.disk)
                } else {
                    Text("停止中").font(.caption2).foregroundStyle(.tertiary)
                }
                if let status = item.lastExitStatus, status != 0 {
                    Text("終了コード \(status)").font(.caption2).foregroundStyle(.orange)
                }
            }

            if item.scope.isEditable {
                Toggle("", isOn: Binding(
                    get: { !item.isDisabled },
                    set: { pendingToggle = (item, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contextMenu {
            Button("設定ファイルを Finder で表示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
            Button("ラベルをコピー") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.label, forType: .string)
            }
        }
    }

    private func apply(_ pending: (item: StartupItem, enable: Bool)) {
        if let error = StartupMonitor.setEnabled(pending.enable, item: pending.item) {
            message = error
        }
        Task { await engine.refreshStartupNow() }
    }
}
