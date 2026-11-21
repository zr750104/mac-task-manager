import SwiftUI
import AppKit

/// 機械式タコメーター風のメーター。
///
/// 金属のベゼル・黒い文字盤・白い目盛りと数字・赤いレッドゾーン・オレンジの針で、
/// 本物の計器のように見せる。文字盤は外観（ライト／ダーク）に関係なく黒にしている。
///
/// グラフと同じく、動きはすべて Core Animation に任せている。
/// SwiftUI のアニメーションで針を動かすと、毎秒ウインドウ全体の再計算が走って重くなるため。
struct MetricGauge: NSViewRepresentable {
    /// 0〜1。範囲外は丸める。
    var ratio: Double
    /// カードのテーマ色。文字盤の縁の細い差し色にだけ使う。
    var color: Color
    /// ここから上がレッドゾーン（0〜1）
    var redline: Double = 0.85
    /// true なら「少ないほど危ない」向き（バッテリー残量など）。0〜redline がレッドゾーンになる。
    var lowZone = false
    /// 値を取得できないときは針を 0 に置いて暗く表示する。
    var available = true
    /// 小さいメーター用。数字や倍率表示を省く。
    var compact = false
    /// 目盛りの数字の区切り数（0〜10 なら 10）
    var intervals = 10
    /// 文字盤に出す倍率（例：「×10 %」）。車の「×1000 r/min」にあたる。
    var multiplier: String? = nil
    /// 表示した直後の「振り切り」演出を始めるまでの遅れ（カードごとに少しずらす）
    var ignitionDelay: Double = 0

    func makeNSView(context: Context) -> GaugeLayerView { GaugeLayerView() }

    func updateNSView(_ view: GaugeLayerView, context: Context) {
        view.update(ratio: ratio, color: NSColor(color), redline: redline, lowZone: lowZone,
                    available: available, compact: compact, intervals: intervals,
                    multiplier: multiplier, ignitionDelay: ignitionDelay,
                    animated: !context.environment.accessibilityReduceMotion)
    }
}

/// メーター本体。文字盤や目盛りは大きさや設定が変わったときだけ作り直し、
/// 毎秒の更新では針の角度とランプだけを変える。
final class GaugeLayerView: NSView {
    /// 針の振れ幅（270°）。左下から右下まで時計回りに振れる。
    private static let sweep = CGFloat.pi * 3 / 2
    /// 0 の位置（225°、左下）
    private static let startAngle = CGFloat.pi * 5 / 4

    private let bezel = CAGradientLayer()
    private let bezelMask = CAShapeLayer()
    private let face = CAGradientLayer()
    private let accentRing = CAShapeLayer()
    private let glass = CAGradientLayer()
    private let glassMask = CAShapeLayer()
    private let redArc = CAShapeLayer()
    private let minorTicks = CAShapeLayer()
    private let majorTicks = CAShapeLayer()
    private let redTicks = CAShapeLayer()
    private let labels = CALayer()
    private let lamp = CAShapeLayer()
    /// 回転させる入れ物。中に針と尾を入れる。
    private let needle = CALayer()
    private let needleBody = CAShapeLayer()
    private let needleTail = CAShapeLayer()
    private let hubRing = CAGradientLayer()
    private let hubCap = CAShapeLayer()

    private var ratio: CGFloat = 0
    /// 最後に針（モデル値）へ反映した値。小さな変化が積み重なったときも追いつけるよう、
    /// 直前の受け取り値ではなくこちらと比べる。
    private var displayedRatio: CGFloat = 0
    private var color = NSColor.systemBlue
    private var redline: CGFloat = 0.85
    private var lowZone = false
    private var available = true
    private var compact = false
    private var intervals = 10
    private var multiplier: String?
    private var ignitionDelay: Double = 0
    private var animated = true
    private var builtSize: CGSize = .zero
    private var hasIgnited = false
    /// 振り切り演出の終わる時刻。それまでは針を動かさず、終わってから最新の値へ寄せる。
    private var ignitionEnd: CFTimeInterval = 0

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        bezel.mask = bezelMask
        face.type = .radial
        face.startPoint = CGPoint(x: 0.5, y: 0.5)
        face.endPoint = CGPoint(x: 1, y: 1)
        face.masksToBounds = true
        glass.mask = glassMask
        for shape in [accentRing, redArc] {
            shape.fillColor = nil
            shape.lineCap = .butt
        }
        for shape in [minorTicks, majorTicks, redTicks] {
            shape.fillColor = nil
            shape.lineCap = .butt
        }
        hubRing.masksToBounds = true
        needle.addSublayer(needleTail)
        needle.addSublayer(needleBody)
        for sublayer in [bezel, face, accentRing, redArc, minorTicks, majorTicks, redTicks,
                         labels, lamp, needle, hubRing, hubCap, glass] as [CALayer] {
            layer?.addSublayer(sublayer)
        }

        // 形や色を差し替えたときに Core Animation が勝手に付ける動きは使わない。
        let none: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(),
                                        "transform": NSNull(), "strokeColor": NSNull(),
                                        "fillColor": NSNull(), "colors": NSNull(),
                                        "opacity": NSNull(), "frame": NSNull(),
                                        "lineWidth": NSNull(), "anchorPoint": NSNull(),
                                        "cornerRadius": NSNull(), "sublayers": NSNull(),
                                        "contents": NSNull(), "contentsScale": NSNull(),
                                        "hidden": NSNull()]
        for sublayer in allLayers { sublayer.actions = none }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    private var allLayers: [CALayer] {
        [bezel, bezelMask, face, accentRing, glass, glassMask, redArc, minorTicks, majorTicks,
         redTicks, labels, lamp, needle, needleBody, needleTail, hubRing, hubCap]
    }

    // MARK: - 寸法

    private static func angle(for ratio: CGFloat) -> CGFloat {
        startAngle - sweep * ratio
    }

    /// 針は真上向きに作ってあるので、目盛りの角度から 90° 引いた分だけ回す。
    private static func rotation(for ratio: CGFloat) -> CGFloat {
        angle(for: ratio) - .pi / 2
    }

    // MARK: - 更新

    func update(ratio newRatio: Double, color newColor: NSColor, redline newRedline: Double,
                lowZone newLowZone: Bool = false,
                available newAvailable: Bool, compact newCompact: Bool, intervals newIntervals: Int,
                multiplier newMultiplier: String?, ignitionDelay delay: Double, animated newAnimated: Bool) {
        let target = newAvailable && newRatio.isFinite ? CGFloat(min(1, max(0, newRatio))) : 0
        let clampedRedline = CGFloat(min(1, max(0, newRedline)))
        let styleChanged = newColor != color || clampedRedline != redline || newLowZone != lowZone
            || newAvailable != available || newCompact != compact
            || newIntervals != intervals || newMultiplier != multiplier
        // 作り直しの前に、今見えている針の角度を取っておく（作り直すとモデル値が変わるため）。
        let visibleRotation = currentRotation()
        ratio = target
        color = newColor
        redline = clampedRedline
        lowZone = newLowZone
        available = newAvailable
        compact = newCompact
        intervals = max(1, newIntervals)
        multiplier = newMultiplier
        ignitionDelay = delay
        animated = newAnimated

        guard bounds.width > 1, bounds.height > 1 else { return }
        if styleChanged { rebuild() }

        if !hasIgnited {
            ignite()
        } else if abs(target - displayedRatio) > 0.0005 {
            moveNeedle(from: visibleRotation)
        }
    }

    /// 今見えている針の角度。動いていなければモデル値。
    private func currentRotation() -> CGFloat {
        (needle.presentation()?.value(forKeyPath: "transform.rotation.z") as? NSNumber)
            .map { CGFloat($0.doubleValue) } ?? Self.rotation(for: displayedRatio)
    }

    override func layout() {
        super.layout()
        guard bounds.size != builtSize else { return }
        rebuild()
        // 大きさが決まって初めて描けるので、最初の振り切りはここで始めることが多い。
        if !hasIgnited, bounds.width > 1, bounds.height > 1 { ignite() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild()
    }

    /// 表示した直後に、針を一度最大まで振ってから現在値へ戻す（エンジン始動のような演出）。
    private func ignite() {
        hasIgnited = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyNeedle(ratio)
        CATransaction.commit()
        guard animated else { return }

        let start = CACurrentMediaTime() + ignitionDelay
        let duration: CFTimeInterval = 1.25
        ignitionEnd = start + duration

        let swing = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        swing.values = [Self.rotation(for: 0), Self.rotation(for: 1), Self.rotation(for: ratio)]
        swing.keyTimes = [0, 0.45, 1]
        swing.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut),
                                 CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)]
        swing.duration = duration
        swing.beginTime = start
        swing.fillMode = .backwards
        needle.add(swing, forKey: "swing")

        // 演出の途中で届いた値は、演出が終わった位置からばねで寄せる。
        // 演出中はモデル値を変えないので、終わった瞬間に針が飛ぶことはない。
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, ignitionEnd - CACurrentMediaTime()) + 0.02) {
            [weak self] in
            guard let self, abs(self.ratio - self.displayedRatio) > 0.0005 else { return }
            self.moveNeedle(from: Self.rotation(for: self.displayedRatio))
        }
    }

    /// 針をばねの動きで新しい値へ動かす。少し行き過ぎてから止まる。
    /// - Parameter fromRotation: 動き始めの角度。途中まで動いている針は今見えている角度から動かす（飛ばないように）。
    private func moveNeedle(from fromRotation: CGFloat) {
        // 振り切り中は何もしない。演出が終わってから最新の値へ寄せる。
        guard CACurrentMediaTime() >= ignitionEnd else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyNeedle(ratio)
        CATransaction.commit()
        guard animated else { return }

        needle.add(Self.spring(from: fromRotation, to: Self.rotation(for: ratio)), forKey: "swing")
    }

    /// 次の値が届くまでの時間いっぱいを使って動かすばね。
    ///
    /// すぐ動き切って止まると、更新のたびに「カクッ」と進むように見える。
    /// 更新間隔に合わせて収まる柔らかさにすると、針が止まらず滑らかに動き続ける。
    /// 減衰はやや弱め（0.75）にして、本物の針のように少しだけ行き過ぎて戻す。
    private static func spring(from: CGFloat, to: CGFloat) -> CASpringAnimation {
        let interval = min(1.5, max(0.3, AppSettings.shared.refreshRate.rawValue))
        // 収まり切る少し前に次の値が届くくらいが、いちばん途切れなく見える。
        let settle = interval * 1.25
        let dampingRatio = 0.75
        // 振れが収まるまでの時間 ≒ 4 / (減衰比 × 固有角振動数)
        let omega = 4 / (dampingRatio * settle)
        let spring = CASpringAnimation(keyPath: "transform.rotation.z")
        spring.fromValue = from
        spring.toValue = to
        spring.mass = 1
        spring.stiffness = omega * omega
        spring.damping = 2 * dampingRatio * omega
        spring.duration = spring.settlingDuration
        return spring
    }

    /// 現在値に合わせて針の角度と警告ランプを決める（動きは付けない）。
    private func applyNeedle(_ value: CGFloat) {
        needle.setValue(Self.rotation(for: value), forKeyPath: "transform.rotation.z")
        displayedRatio = value
        let lit = available && isInRedZone(value)
        lamp.fillColor = lit ? NSColor(red: 1, green: 0.2, blue: 0.12, alpha: 1).cgColor
                             : NSColor(red: 0.32, green: 0.06, blue: 0.05, alpha: 1).cgColor
        lamp.strokeColor = lit ? NSColor(red: 1, green: 0.45, blue: 0.35, alpha: 0.9).cgColor
                               : NSColor(white: 0, alpha: 0.6).cgColor
    }

    // MARK: - 形と色

    private func rebuild() {
        let size = bounds.size
        builtSize = size
        guard size.width > 1, size.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for sublayer in allLayers { sublayer.contentsScale = scale }
        for shape in [accentRing, redArc, minorTicks, majorTicks, redTicks, lamp, hubCap] {
            shape.frame = bounds
        }

        let r = max(4, min(size.width, size.height) / 2 - 1)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let accent = color.usingColorSpace(.deviceRGB) ?? color

        // 金属のベゼル：左上が明るく右下が暗い、削り出しの輪
        let bezelWidth = max(2, r * 0.075)
        bezel.frame = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        bezel.colors = [NSColor(white: 0.86, alpha: 1), NSColor(white: 0.42, alpha: 1),
                        NSColor(white: 0.18, alpha: 1), NSColor(white: 0.55, alpha: 1)]
            .map(\.cgColor)
        bezel.locations = [0, 0.35, 0.7, 1]
        bezel.startPoint = CGPoint(x: 0.15, y: 1)
        bezel.endPoint = CGPoint(x: 0.85, y: 0)
        let ring = CGMutablePath()
        ring.addEllipse(in: bezel.bounds)
        ring.addEllipse(in: bezel.bounds.insetBy(dx: bezelWidth, dy: bezelWidth))
        bezelMask.frame = bezel.bounds
        bezelMask.path = ring
        bezelMask.fillRule = .evenOdd

        // 黒い文字盤：中心がわずかに明るい
        let faceRadius = r - bezelWidth
        face.frame = CGRect(x: center.x - faceRadius, y: center.y - faceRadius,
                            width: faceRadius * 2, height: faceRadius * 2)
        face.cornerRadius = faceRadius
        face.colors = [NSColor(red: 0.16, green: 0.165, blue: 0.18, alpha: 1),
                       NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1),
                       NSColor(red: 0.03, green: 0.03, blue: 0.035, alpha: 1)].map(\.cgColor)
        face.locations = [0, 0.7, 1]

        // 文字盤の縁にテーマ色の細い差し色
        accentRing.path = CGPath(ellipseIn: CGRect(x: center.x - faceRadius + 1, y: center.y - faceRadius + 1,
                                                   width: faceRadius * 2 - 2, height: faceRadius * 2 - 2),
                                 transform: nil)
        accentRing.lineWidth = max(0.8, r * 0.012)
        accentRing.strokeColor = accent.withAlphaComponent(available ? 0.65 : 0.25).cgColor

        // 目盛り：数字の位置に太い目盛り、その間に細い目盛り
        let tickOuter = faceRadius * 0.93
        let minorPerMajor = compact ? 1 : (r >= 60 ? 5 : 2)
        let steps = intervals * minorPerMajor
        let majorPath = CGMutablePath()
        let redPath = CGMutablePath()
        let minorPath = CGMutablePath()
        for step in 0...steps {
            let value = CGFloat(step) / CGFloat(steps)
            let isMajor = step % minorPerMajor == 0
            let length = isMajor ? faceRadius * 0.15 : faceRadius * 0.07
            let target: CGMutablePath = isInRedZone(value) ? redPath : (isMajor ? majorPath : minorPath)
            let theta = Self.angle(for: value)
            target.move(to: point(center, tickOuter, theta))
            target.addLine(to: point(center, tickOuter - length, theta))
        }
        majorTicks.path = majorPath
        minorTicks.path = minorPath
        redTicks.path = redPath
        majorTicks.lineWidth = max(1, faceRadius * 0.028)
        minorTicks.lineWidth = max(0.6, faceRadius * 0.012)
        redTicks.lineWidth = max(0.8, faceRadius * 0.022)
        majorTicks.strokeColor = NSColor(white: 0.95, alpha: available ? 0.95 : 0.4).cgColor
        minorTicks.strokeColor = NSColor(white: 0.85, alpha: available ? 0.55 : 0.25).cgColor
        redTicks.strokeColor = NSColor(red: 0.95, green: 0.18, blue: 0.12, alpha: available ? 1 : 0.4).cgColor

        // レッドゾーン：目盛りの外側に沿った赤い帯
        let redWidth = max(1.5, faceRadius * 0.05)
        let redPathArc = CGMutablePath()
        let redRange: (CGFloat, CGFloat) = lowZone ? (0, redline) : (redline, 1)
        if redRange.1 > redRange.0 {
            redPathArc.addArc(center: center, radius: tickOuter + redWidth * 0.2,
                              startAngle: Self.angle(for: redRange.0), endAngle: Self.angle(for: redRange.1),
                              clockwise: true)
        }
        redArc.path = redPathArc
        redArc.lineWidth = redWidth
        redArc.strokeColor = NSColor(red: 0.85, green: 0.1, blue: 0.08, alpha: available ? 0.9 : 0.35).cgColor

        // 数字と倍率表示
        labels.sublayers?.forEach { $0.removeFromSuperlayer() }
        labels.frame = bounds
        if !compact, faceRadius >= 30 {
            let fontSize = max(6.5, min(15, faceRadius * 0.15))
            let numeralRadius = tickOuter - faceRadius * 0.15 - fontSize * 0.85
            // 小さいときは 1 つおきに出して詰まりを避ける。
            let every = faceRadius < 58 ? 2 : 1
            for index in stride(from: 0, through: intervals, by: every) {
                let value = CGFloat(index) / CGFloat(intervals)
                let red = isInRedZone(value)
                let text = makeText("\(index)", size: fontSize, weight: .semibold,
                                    color: red ? NSColor(red: 1, green: 0.3, blue: 0.22, alpha: 1)
                                               : NSColor(white: 0.93, alpha: 1),
                                    scale: scale)
                place(text, at: point(center, numeralRadius, Self.angle(for: value)), width: fontSize * 2.4)
                labels.addSublayer(text)
            }
            if let multiplier {
                let small = max(6, fontSize * 0.68)
                let text = makeText(multiplier, size: small, weight: .medium,
                                    color: NSColor(white: 0.62, alpha: 1), scale: scale)
                place(text, at: CGPoint(x: center.x, y: center.y - faceRadius * 0.36),
                      width: faceRadius * 1.3)
                labels.addSublayer(text)
            }
        }
        labels.opacity = available ? 1 : 0.4

        // 警告ランプ（レッドゾーンで点灯）
        let lampRadius = max(1.5, faceRadius * 0.045)
        lamp.isHidden = compact
        lamp.path = CGPath(ellipseIn: CGRect(x: center.x - lampRadius, y: center.y - faceRadius * 0.6 - lampRadius,
                                             width: lampRadius * 2, height: lampRadius * 2), transform: nil)
        lamp.lineWidth = max(0.5, lampRadius * 0.35)

        // 針：軸から先へ細くなるオレンジの針と、反対側の黒い尾（釣り合いのおもり）
        let length = faceRadius * 0.86
        let tail = faceRadius * 0.24
        let base = max(1.1, faceRadius * 0.032)
        let width = base * 2 + 4
        needle.bounds = CGRect(x: 0, y: 0, width: width, height: length + tail)
        needle.anchorPoint = CGPoint(x: 0.5, y: tail / (length + tail))
        needle.position = center
        let mid = width / 2
        let body = CGMutablePath()
        body.move(to: CGPoint(x: mid - base, y: tail))
        body.addLine(to: CGPoint(x: mid - 0.45, y: tail + length))
        body.addLine(to: CGPoint(x: mid + 0.45, y: tail + length))
        body.addLine(to: CGPoint(x: mid + base, y: tail))
        body.closeSubpath()
        needleBody.frame = needle.bounds
        needleBody.path = body
        needleBody.fillColor = NSColor(red: 1.0, green: 0.42, blue: 0.1, alpha: available ? 1 : 0.35).cgColor
        let tailPath = CGMutablePath()
        tailPath.addRoundedRect(in: CGRect(x: mid - base * 1.5, y: 0, width: base * 3, height: tail + base),
                                cornerWidth: base * 1.2, cornerHeight: base * 1.2)
        needleTail.frame = needle.bounds
        needleTail.path = tailPath
        needleTail.fillColor = NSColor(white: 0.12, alpha: 1).cgColor

        // 軸キャップ：金属の輪の中に黒い蓋
        let hubRadius = max(2.5, faceRadius * 0.12)
        hubRing.frame = CGRect(x: center.x - hubRadius, y: center.y - hubRadius,
                               width: hubRadius * 2, height: hubRadius * 2)
        hubRing.cornerRadius = hubRadius
        hubRing.colors = [NSColor(white: 0.85, alpha: 1), NSColor(white: 0.3, alpha: 1)].map(\.cgColor)
        hubRing.startPoint = CGPoint(x: 0.2, y: 1)
        hubRing.endPoint = CGPoint(x: 0.8, y: 0)
        let capRadius = hubRadius * 0.68
        hubCap.path = CGPath(ellipseIn: CGRect(x: center.x - capRadius, y: center.y - capRadius,
                                               width: capRadius * 2, height: capRadius * 2), transform: nil)
        hubCap.fillColor = NSColor(white: 0.07, alpha: 1).cgColor

        // ガラスの映り込み：上半分にごく薄い光
        glass.frame = face.frame
        glass.colors = [NSColor(white: 1, alpha: 0.10).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        glass.startPoint = CGPoint(x: 0.5, y: 1)
        glass.endPoint = CGPoint(x: 0.5, y: 0.45)
        glassMask.frame = glass.bounds
        glassMask.path = CGPath(ellipseIn: CGRect(x: faceRadius * 0.12, y: faceRadius * 0.55,
                                                  width: faceRadius * 1.76, height: faceRadius * 1.4),
                                transform: nil)

        // 針の位置は変えない。新しい値へ動かすのは ignite() と moveNeedle() だけにして、
        // 目盛りの倍率や色が変わった瞬間にも、針がばねで動くようにする。
        applyNeedle(displayedRatio)
    }

    /// レッドゾーンの中か。目盛りの境目ちょうども含める。
    private func isInRedZone(_ value: CGFloat) -> Bool {
        lowZone ? value <= redline + 0.0001 : value >= redline - 0.0001
    }

    private func makeText(_ string: String, size: CGFloat, weight: NSFont.Weight,
                          color: NSColor, scale: CGFloat) -> CATextLayer {
        let text = CATextLayer()
        text.string = string
        text.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        text.fontSize = size
        text.foregroundColor = color.cgColor
        text.alignmentMode = .center
        text.contentsScale = scale
        text.truncationMode = .end
        text.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        return text
    }

    /// 文字の中心が point に来るように置く。
    private func place(_ text: CATextLayer, at point: CGPoint, width: CGFloat) {
        let height = text.fontSize * 1.25
        text.frame = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
    }

    private func point(_ center: CGPoint, _ radius: CGFloat, _ theta: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta))
    }
}
