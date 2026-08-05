// アプリアイコン（.icns）を生成する補助スクリプト。
// 使い方: swift Tools/makeicon.swift <出力先ディレクトリ>
import AppKit

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// 棒グラフ風のメーターを角丸の背景に描いたアイコン。
func drawIcon(size: CGFloat) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(size), pixelsHigh: Int(size),
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let context = NSGraphicsContext.current?.cgContext else { return nil }

    // 背景（濃紺のグラデーション）
    let radius = size * 0.223
    let background = CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                            cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(background)
    context.clip()
    let colors = [NSColor(calibratedRed: 0.13, green: 0.17, blue: 0.29, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.13, alpha: 1).cgColor]
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors as CFArray, locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: size),
                                   end: CGPoint(x: size, y: 0),
                                   options: [])
    }

    // 棒グラフ（左から CPU/メモリ/GPU/ディスクを連想させる 4 本）
    let bars: [(height: CGFloat, color: NSColor)] = [
        (0.34, NSColor(calibratedRed: 0.24, green: 0.55, blue: 0.95, alpha: 1)),
        (0.60, NSColor(calibratedRed: 0.65, green: 0.42, blue: 0.92, alpha: 1)),
        (0.44, NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.20, alpha: 1)),
        (0.74, NSColor(calibratedRed: 0.35, green: 0.80, blue: 0.55, alpha: 1))
    ]
    let barWidth = size * 0.108
    let spacing = size * 0.055
    let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * spacing
    var x = (size - totalWidth) / 2
    let baseY = size * 0.20

    for bar in bars {
        let height = size * bar.height
        let rect = CGRect(x: x, y: baseY, width: barWidth, height: height)
        let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2.4,
                          cornerHeight: barWidth / 2.4, transform: nil)
        context.addPath(path)
        context.setFillColor(bar.color.cgColor)
        context.fillPath()
        x += barWidth + spacing
    }

    // 折れ線（稼働率の推移を示すアクセント）
    let points: [CGPoint] = [
        CGPoint(x: size * 0.16, y: size * 0.62),
        CGPoint(x: size * 0.34, y: size * 0.76),
        CGPoint(x: size * 0.50, y: size * 0.66),
        CGPoint(x: size * 0.68, y: size * 0.84),
        CGPoint(x: size * 0.85, y: size * 0.72)
    ]
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
    context.setLineWidth(size * 0.035)
    context.setLineJoin(.round)
    context.setLineCap(.round)
    context.beginPath()
    context.move(to: points[0])
    for point in points.dropFirst() { context.addLine(to: point) }
    context.strokePath()

    context.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for entry in sizes {
    guard let rep = drawIcon(size: entry.pixels),
          let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("アイコン \(entry.name) の生成に失敗しました\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent("\(entry.name).png"))
}
print("生成しました: \(iconset.path)")
