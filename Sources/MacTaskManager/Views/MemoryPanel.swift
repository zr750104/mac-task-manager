import SwiftUI

struct MemoryPanel: View {
    @EnvironmentObject private var engine: MetricsEngine

    @State private var isConfirmingPurge = false
    @State private var isPurging = false
    @State private var purgeMessage: String?
    /// 解放前の使用量。効果を示すために覚えておく。
    @State private var memoryBeforePurge: UInt64?

    var body: some View {
        let memory = engine.snapshot.memory

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: "メモリ",
                            subtitle: "\(Fmt.bytes(memory.total)) ユニファイドメモリ",
                            value: Fmt.bytes(memory.used),
                            valueColor: Palette.memory)

                purgeControls

                MetricChart(values: engine.memoryHistory.padded, maxValue: 1, color: Palette.memory)
                    .frame(height: 150)

                // 内訳の帯グラフ
                VStack(alignment: .leading, spacing: 6) {
                    Text("メモリの内訳").font(.headline)
                    SegmentedBar(segments: [
                        .init(label: "アプリ", value: Double(memory.app), color: Palette.memory),
                        .init(label: "確保済み", value: Double(memory.wired), color: Palette.performanceCore),
                        .init(label: "圧縮", value: Double(memory.compressed), color: Palette.gpu),
                        .init(label: "キャッシュ", value: Double(memory.cachedFiles), color: Palette.efficiencyCore)
                    ], total: Double(memory.total))

                    // 幅が狭いと 5 項目が並びきらないので折り返す。
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)],
                              alignment: .leading, spacing: 4) {
                        LegendLabel(color: Palette.memory, text: "アプリメモリ", value: Fmt.bytes(memory.app))
                        LegendLabel(color: Palette.performanceCore, text: "確保済み", value: Fmt.bytes(memory.wired))
                        LegendLabel(color: Palette.gpu, text: "圧縮", value: Fmt.bytes(memory.compressed))
                        LegendLabel(color: Palette.efficiencyCore, text: "キャッシュ", value: Fmt.bytes(memory.cachedFiles))
                        LegendLabel(color: .gray.opacity(0.4), text: "空き", value: Fmt.bytes(memory.free))
                    }
                }

                TileGrid(items: [
                    .init("使用中", Fmt.bytes(memory.used),
                          caption: Fmt.percent(memory.usedRatio) + " / \(Fmt.bytes(memory.total))",
                          color: Palette.memory, emphasized: true),
                    .init("メモリプレッシャー", memory.pressureLevel.label,
                          caption: Fmt.percent(memory.pressure),
                          color: pressureColor(memory.pressureLevel), emphasized: true),
                    .init("スワップ使用量", Fmt.bytes(memory.swapUsed),
                          caption: "確保 \(Fmt.bytes(memory.swapTotal))",
                          color: memory.swapUsed > 0 ? Palette.gpu : .primary, emphasized: true)
                ], minimumWidth: 170)

                // プレッシャーの推移
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("メモリプレッシャーの推移").font(.headline)
                        Spacer()
                        Text("確保済み + 圧縮メモリが物理メモリに占める割合")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    MetricChart(values: engine.pressureHistory.padded, maxValue: 1,
                                color: pressureColor(memory.pressureLevel))
                        .frame(height: 110)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("ページング").font(.headline)
                    TileGrid(items: [
                        .init("ページイン/秒", Fmt.count(Int(memory.pageInsPerSec))),
                        .init("ページアウト/秒", Fmt.count(Int(memory.pageOutsPerSec))),
                        .init("スワップイン/秒", Fmt.count(Int(memory.swapInsPerSec))),
                        .init("スワップアウト/秒", Fmt.count(Int(memory.swapOutsPerSec))),
                        .init("ページフォルト/秒", Fmt.count(Int(memory.faultsPerSec)))
                    ], minimumWidth: 130)
                    if memory.swapUsed > memory.total / 8 {
                        Label("スワップの使用量が多く、メモリが不足気味です。使っていないアプリを終了すると改善します。",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                    }
                }
            }
        }
    }

    // MARK: - メモリ解放

    private var purgeControls: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("メモリを解放")
                    .font(.callout.weight(.medium))
                Text("ディスクキャッシュを破棄して、確保されているメモリを開放します。管理者パスワードが必要です。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isPurging {
                ProgressView().controlSize(.small)
            }
            Button {
                memoryBeforePurge = engine.snapshot.memory.used
                isConfirmingPurge = true
            } label: {
                Label("解放する", systemImage: "arrow.counterclockwise.circle")
            }
            .disabled(isPurging || !MemoryReclaimer.isAvailable)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
        .confirmationDialog("メモリを解放しますか？", isPresented: $isConfirmingPurge) {
            Button("解放する") { runPurge() }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("""
            macOS の purge コマンドを実行します。管理者パスワードの入力を求められます。

            これはファイルのキャッシュを捨てる操作で、アプリが使用中のメモリは減りません。\
            またキャッシュが消えるため、直後はファイルの読み込みが一時的に遅くなります。

            macOS はメモリを自動で管理するので、通常は実行する必要はありません。\
            メモリ不足を解消したい場合は、使っていないアプリを終了するほうが効果的です。
            """)
        }
        .alert("メモリ解放", isPresented: .constant(purgeMessage != nil)) {
            Button("OK") { purgeMessage = nil }
        } message: {
            Text(purgeMessage ?? "")
        }
    }

    private func runPurge() {
        isPurging = true
        Task {
            let result = await MemoryReclaimer.purge()
            // 解放直後は統計が落ち着かないので少し待ってから比較する。
            try? await Task.sleep(for: .seconds(2))
            isPurging = false
            switch result {
            case .success:
                let after = engine.snapshot.memory.used
                if let before = memoryBeforePurge, before > after {
                    purgeMessage = "\(Fmt.bytes(before - after)) 分のメモリが解放されました。\n"
                        + "（\(Fmt.bytes(before)) → \(Fmt.bytes(after))）"
                } else {
                    purgeMessage = "解放を実行しました。解放できるキャッシュがなかったため、使用量はほとんど変わっていません。"
                }
            case .cancelled:
                purgeMessage = nil
            case .failed(let reason):
                purgeMessage = "解放できませんでした。\n\(reason)"
            }
            memoryBeforePurge = nil
        }
    }

    private func pressureColor(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: return Palette.disk
        case .warning: return Palette.gpu
        case .critical: return .red
        }
    }
}
