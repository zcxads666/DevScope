import AppKit

// 生成 DevScope 应用图标（macOS 规范：1024 画布 / 824 主体 squircle）
// 输出：App/AppIcon.icns

let outputDir = "build/icon.iconset"

func drawScene(size: CGFloat) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("无绘图上下文") }
    let scale = size / 1024
    let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let radius = 185.4 * scale
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // 底部投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 24 * scale,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    NSColor.white.setFill()
    bodyPath.fill()
    ctx.restoreGState()

    // 主体渐变（teal → petrol，与面板头部一致）
    let colors = [
        NSColor(srgbRed: 0.02, green: 0.71, blue: 0.65, alpha: 1).cgColor,
        NSColor(srgbRed: 0.00, green: 0.42, blue: 0.52, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: colors, locations: [0, 1])!
    ctx.saveGState()
    bodyPath.addClip()
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY),
                           options: [])
    ctx.restoreGState()

    // 顶部高光描边（玻璃质感）
    let highlight = NSBezierPath(roundedRect: body.insetBy(dx: 1.5 * scale, dy: 1.5 * scale),
                                 xRadius: radius - 1.5 * scale, yRadius: radius - 1.5 * scale)
    NSColor.white.withAlphaComponent(0.35).setStroke()
    highlight.lineWidth = 3 * scale
    highlight.stroke()

    // 白色听诊器 + 轻投影
    if let base = NSImage(systemSymbolName: "stethoscope", accessibilityDescription: nil),
       let symbol = base.withSymbolConfiguration(.init(pointSize: 380 * scale, weight: .bold)) {
        let targetW = body.width * 0.52
        let aspect = symbol.size.height / max(symbol.size.width, 1)
        let drawRect = NSRect(x: body.midX - targetW / 2,
                              y: body.midY - targetW * aspect / 2,
                              width: targetW, height: targetW * aspect)
        let tinted = NSImage(size: drawRect.size)
        tinted.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: drawRect.size))
        NSColor.white.setFill()
        NSRect(origin: .zero, size: drawRect.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4 * scale), blur: 8 * scale,
                      color: NSColor.black.withAlphaComponent(0.2).cgColor)
        tinted.draw(in: drawRect)
        ctx.restoreGState()
    }
}

func writePNG(_ pixels: Int, name: String) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        fatalError("创建位图失败")
    }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawScene(size: CGFloat(pixels))
    NSGraphicsContext.current = nil
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("PNG 编码失败") }
    try! data.write(to: URL(fileURLWithPath: outputDir + "/" + name))
}

let fm = FileManager.default
try! fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let specs: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in specs { writePNG(px, name: name) }

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", outputDir, "-o", "App/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print("App/AppIcon.icns 已生成（exit \(iconutil.terminationStatus)）")
