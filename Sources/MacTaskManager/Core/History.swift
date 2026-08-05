import Foundation

/// 固定長のリングバッファ。グラフ描画用の時系列を一定件数だけ保持する。
struct History: Sendable {
    private(set) var values: [Double]
    let capacity: Int

    init(capacity: Int = 120) {
        self.capacity = capacity
        self.values = []
        self.values.reserveCapacity(capacity)
    }

    mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    /// 直近の値。まだ何も入っていなければ 0。
    var latest: Double { values.last ?? 0 }

    var maximum: Double { values.max() ?? 0 }

    var average: Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// 左を過去・右を現在として、常に capacity 個ぶんの幅で描けるよう先頭を 0 で埋めた配列。
    var padded: [Double] {
        guard values.count < capacity else { return values }
        return Array(repeating: 0, count: capacity - values.count) + values
    }
}
