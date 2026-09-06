import SwiftUI
import AppKit

struct ProcessPanel: View {
    @EnvironmentObject private var engine: MetricsEngine

    @State private var search = ""
    @State private var onlyMyProcesses = false
    @State private var selection: ProcessRow.ID?
    @State private var sortOrder = [KeyPathComparator(\ProcessRow.cpuPercent, order: .reverse)]
    @State private var message: String?
    @State private var pendingTermination: (row: ProcessRow, force: Bool)?
    /// 列の表示/非表示と並び順。ヘッダーを右クリックして切り替えられる。
    @State private var columnCustomization = TableColumnCustomization<ProcessRow>()

    /// 絞り込み・並べ替え済みの表示用データ。
    /// 計測値は毎秒更新されるが、プロセス一覧は 2 秒間隔なので、
    /// 毎秒 800 件超を並べ替え直さないようキャッシュしておく。
    @State private var rows: [ProcessRow] = []
    @State private var totals = Totals()

    private struct Totals: Equatable {
        var count = 0
        var mine = 0
        var cpu: Double = 0
        var memory: UInt64 = 0
        var threads = 0
    }

    private func recompute() {
        var list = engine.processes
        if onlyMyProcesses {
            list = list.filter(\.isOwnedByCurrentUser)
        }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(query)
                || String($0.pid).contains(query)
                || $0.user.lowercased().contains(query)
                || $0.executablePath.lowercased().contains(query)
            }
        }
        rows = list.sorted(using: sortOrder)

        let all = engine.processes
        totals = Totals(count: all.count,
                        mine: all.count(where: \.isOwnedByCurrentUser),
                        cpu: all.reduce(0) { $0 + $1.cpuPercent },
                        memory: all.reduce(UInt64(0)) { $0 + $1.memory },
                        threads: all.reduce(0) { $0 + $1.threads })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            controls
            table
        }
        .onAppear { recompute() }
        .onChange(of: engine.processes) { _, _ in recompute() }
        .onChange(of: search) { _, _ in recompute() }
        .onChange(of: onlyMyProcesses) { _, _ in recompute() }
        .onChange(of: sortOrder) { _, _ in recompute() }
        .alert("プロセスを終了できません", isPresented: .constant(message != nil)) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .confirmationDialog(confirmationTitle, isPresented: .constant(pendingTermination != nil)) {
            if let pending = pendingTermination {
                Button(pending.force ? "強制終了" : "終了", role: .destructive) {
                    terminate(pending.row, force: pending.force)
                    pendingTermination = nil
                }
            }
            Button("キャンセル", role: .cancel) { pendingTermination = nil }
        } message: {
            if let pending = pendingTermination {
                Text(pending.force
                     ? "「\(pending.row.name)」(PID \(String(pending.row.pid))) を強制終了します。保存していない変更は失われます。"
                     : "「\(pending.row.name)」(PID \(String(pending.row.pid))) に終了を要求します。")
            }
        }
    }

    private var confirmationTitle: String {
        pendingTermination?.force == true ? "プロセスを強制終了しますか？" : "プロセスを終了しますか？"
    }

    // MARK: - 上部

    private var summary: some View {
        TileGrid(items: [
            .init("プロセス数", Fmt.count(totals.count),
                  caption: "自分のプロセス \(Fmt.count(totals.mine)) 個"),
            .init("CPU 使用率の合計", Fmt.cpuPercent(totals.cpu),
                  caption: "100% = 1 コア占有 / 最大 \(engine.info.logicalCores * 100)%",
                  color: Palette.cpu),
            .init("メモリ合計", Fmt.bytes(totals.memory),
                  caption: "共有分を含むため物理メモリを超えることがあります",
                  color: Palette.memory),
            .init("スレッド数", Fmt.count(totals.threads),
                  caption: "取得できたプロセスのみ")
        ])
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("名前・PID・ユーザで検索", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .frame(maxWidth: 320)

            Toggle("自分のプロセスのみ", isOn: $onlyMyProcesses)
                .toggleStyle(.checkbox)

            Spacer()

            if let selected = selectedRow {
                Button {
                    pendingTermination = (selected, false)
                } label: {
                    Label("終了", systemImage: "stop.circle")
                }
                Button {
                    pendingTermination = (selected, true)
                } label: {
                    Label("強制終了", systemImage: "xmark.octagon")
                }
                .tint(.red)
            }

            Button {
                Task { await engine.refreshProcessesNow() }
            } label: {
                Label("更新", systemImage: "arrow.clockwise")
            }
        }
    }

    private var selectedRow: ProcessRow? {
        guard let selection else { return nil }
        return engine.processes.first { $0.id == selection }
    }

    // MARK: - 表

    private var table: some View {
        // 計測値は毎秒更新されるが、その都度 800 行を描き直すと CPU を無駄に食う。
        // 表は Equatable な子ビューに分け、プロセス一覧が実際に変わったときだけ再描画させる。
        ProcessTable(rows: rows,
                     selection: $selection,
                     sortOrder: $sortOrder,
                     columnCustomization: $columnCustomization,
                     onTerminate: { row, force in pendingTermination = (row, force) })
            .equatable()
    }
}

private struct ProcessTable: View, Equatable {
    var rows: [ProcessRow]
    @Binding var selection: ProcessRow.ID?
    @Binding var sortOrder: [KeyPathComparator<ProcessRow>]
    @Binding var columnCustomization: TableColumnCustomization<ProcessRow>
    var onTerminate: (ProcessRow, Bool) -> Void

    /// クロージャは比較できないので、表示に影響する値だけで同一性を判断する。
    static func == (lhs: ProcessTable, rhs: ProcessTable) -> Bool {
        lhs.rows == rhs.rows
            && lhs.selection == rhs.selection
            && lhs.sortOrder == rhs.sortOrder
            && lhs.columnCustomization == rhs.columnCustomization
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder,
              columnCustomization: $columnCustomization) {
            TableColumn("プロセス名", value: \.name) { row in
                HStack(spacing: 6) {
                    // ヘルパープロセスは親アプリのアイコンで表示する。
                    AppIconView(bundlePath: row.appBundlePath,
                                isApp: row.isGUIApp, size: 15)
                    Text(row.name).lineLimit(1)
                    if row.isTranslated {
                        Text("Rosetta")
                            .font(.caption2)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Palette.gpu.opacity(0.25)))
                    }
                }
            }
            .width(min: 180, ideal: 240)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("PID", value: \.pid) { row in
                Text(String(row.pid)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 56, max: 80)
            .customizationID("pid")

            TableColumn("CPU %", value: \.cpuPercent) { row in
                Text(Fmt.cpuPercent(row.cpuPercent))
                    .monospacedDigit()
                    .foregroundStyle(row.cpuPercent >= 50 ? Palette.performanceCore
                                     : (row.cpuPercent >= 10 ? Palette.gpu : .primary))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 66, max: 96)
            .customizationID("cpu")

            TableColumn("メモリ", value: \.memory) { row in
                Text(Fmt.bytes(row.memory))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 76, max: 110)
            .customizationID("memory")

            TableColumn("スレッド", value: \.threads) { row in
                Text(row.threads > 0 ? String(row.threads) : "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, max: 80)
            .customizationID("threads")

            TableColumn("CPU 時間", value: \.cpuTime) { row in
                Text(Fmt.cpuTime(row.cpuTime))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, max: 120)
            .customizationID("cpuTime")

            TableColumn("ディスク読み", value: \.diskReadRate) { row in
                Text(row.isPrecise ? Fmt.rate(row.diskReadRate) : "—")
                    .monospacedDigit()
                    .foregroundStyle(row.diskReadRate > 0 ? Palette.disk : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, max: 120)
            .customizationID("diskRead")

            TableColumn("ディスク書き", value: \.diskWriteRate) { row in
                Text(row.isPrecise ? Fmt.rate(row.diskWriteRate) : "—")
                    .monospacedDigit()
                    .foregroundStyle(row.diskWriteRate > 0 ? Palette.upload : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, max: 120)
            .customizationID("diskWrite")

            TableColumn("ユーザ", value: \.user) { row in
                Text(row.user).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 90, max: 160)
            .customizationID("user")
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: ProcessRow.ID.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("終了（SIGTERM）") { onTerminate(row, false) }
                Button("強制終了（SIGKILL）") { onTerminate(row, true) }
                Divider()
                Button("パスをコピー") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.executablePath.isEmpty ? row.name : row.executablePath,
                                                   forType: .string)
                }
                Button("Finder で表示") {
                    guard !row.executablePath.isEmpty else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.executablePath)])
                }
                .disabled(row.executablePath.isEmpty)
            }
        }
    }
}

extension ProcessPanel {

    private func terminate(_ row: ProcessRow, force: Bool) {
        if let error = engine.terminate(pid: row.pid, name: row.name, force: force) {
            message = error
        } else {
            selection = nil
        }
    }
}
