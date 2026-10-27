// 画 Safarier 的 1024×1024 图标 PNG（星轨罗盘：罗盘指针 + 三条轨道，代表彼此隔离的多个环境）。
// 用法：swift scripts/make-icon.swift OUTPUT.png（build-app.sh 调用，再由 iconutil 转成 .icns）。
import AppKit
import CoreGraphics

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("用法：swift make-icon.swift OUTPUT.png\n".utf8))
    exit(64)
}

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: alpha
    )
}

func cgColor(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> CGColor {
    srgb(hex, alpha).cgColor
}

func renderCanvas(size: Int = 1024, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = nsCtx
    let cg = nsCtx.cgContext
    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)
    cg.interpolationQuality = .high
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func drawSquircleBase(
    _ cg: CGContext,
    topColor: UInt32,
    midColor: UInt32,
    bottomColor: UInt32,
    glowColor: UInt32,
    glowCenter: CGPoint = CGPoint(x: 512, y: 740)
) -> CGPath {
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: rect, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 32, color: srgb(0x000000, 0.38).cgColor)
    cg.setFillColor(cgColor(bottomColor))
    cg.addPath(path)
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(path)
    cg.clip()

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let grad = CGGradient(
        colorsSpace: space,
        colors: [cgColor(topColor), cgColor(midColor), cgColor(bottomColor)] as CFArray,
        locations: [0.0, 0.52, 1.0]
    )!
    cg.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    let radial = CGGradient(
        colorsSpace: space,
        colors: [cgColor(glowColor, 0.55), cgColor(glowColor, 0.0)] as CFArray,
        locations: [0.0, 1.0]
    )!
    cg.drawRadialGradient(
        radial,
        startCenter: glowCenter, startRadius: 0,
        endCenter: glowCenter, endRadius: 520,
        options: [.drawsAfterEndLocation]
    )
    cg.restoreGState()

    cg.saveGState()
    let insetRect = rect.insetBy(dx: 2.5, dy: 2.5)
    let insetPath = CGPath(roundedRect: insetRect, cornerWidth: 183, cornerHeight: 183, transform: nil)
    cg.addPath(insetPath)
    cg.replacePathWithStrokedPath()
    cg.clip()
    let rimGrad = CGGradient(
        colorsSpace: space,
        colors: [cgColor(0xFFFFFF, 0.45), cgColor(0xFFFFFF, 0.08), cgColor(0xFFFFFF, 0.18)] as CFArray,
        locations: [0.0, 0.6, 1.0]
    )!
    cg.setLineWidth(5)
    cg.addPath(insetPath)
    cg.replacePathWithStrokedPath()
    cg.clip()
    cg.drawLinearGradient(rimGrad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    cg.restoreGState()

    return path
}

func drawCompassTicks(_ cg: CGContext, center: CGPoint, radius: CGFloat, count: Int = 72, color: UInt32 = 0xFFFFFF, baseAlpha: CGFloat = 0.55) {
    cg.saveGState()
    for i in 0..<count {
        let angle = CGFloat(i) * (2.0 * .pi / CGFloat(count))
        let isMajor = (i % 6 == 0)
        let isMedium = (i % 2 == 0)
        let innerR = radius - (isMajor ? 28 : (isMedium ? 18 : 11))
        let outerR = radius
        let p1 = CGPoint(x: center.x + cos(angle) * innerR, y: center.y + sin(angle) * innerR)
        let p2 = CGPoint(x: center.x + cos(angle) * outerR, y: center.y + sin(angle) * outerR)
        cg.setStrokeColor(cgColor(color, isMajor ? baseAlpha * 1.35 : (isMedium ? baseAlpha : baseAlpha * 0.6)))
        cg.setLineWidth(isMajor ? 4.5 : 2.5)
        cg.setLineCap(.round)
        cg.move(to: p1)
        cg.addLine(to: p2)
        cg.strokePath()
    }
    cg.restoreGState()
}

func drawCompassNeedle(
    _ cg: CGContext,
    center: CGPoint,
    length: CGFloat,
    halfWidth: CGFloat,
    angleDegrees: CGFloat = 42,
    northLight: UInt32 = 0xFF6B5B,
    northDark: UInt32 = 0xE11D48,
    southLight: UInt32 = 0xFFFFFF,
    southDark: UInt32 = 0xCBD5E1
) {
    cg.saveGState()
    cg.translateBy(x: center.x, y: center.y)
    cg.rotate(by: angleDegrees * .pi / 180.0)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: cgColor(0x000000, 0.45))
    let fullDiamond = CGMutablePath()
    fullDiamond.move(to: CGPoint(x: 0, y: length))
    fullDiamond.addLine(to: CGPoint(x: halfWidth, y: 0))
    fullDiamond.addLine(to: CGPoint(x: 0, y: -length))
    fullDiamond.addLine(to: CGPoint(x: -halfWidth, y: 0))
    fullDiamond.closeSubpath()
    cg.setFillColor(cgColor(0xFFFFFF))
    cg.addPath(fullDiamond)
    cg.fillPath()
    cg.restoreGState()

    let nLeft = CGMutablePath()
    nLeft.move(to: CGPoint(x: 0, y: length))
    nLeft.addLine(to: CGPoint(x: -halfWidth, y: 0))
    nLeft.addLine(to: CGPoint(x: 0, y: 0))
    nLeft.closeSubpath()
    cg.setFillColor(cgColor(northLight))
    cg.addPath(nLeft)
    cg.fillPath()

    let nRight = CGMutablePath()
    nRight.move(to: CGPoint(x: 0, y: length))
    nRight.addLine(to: CGPoint(x: halfWidth, y: 0))
    nRight.addLine(to: CGPoint(x: 0, y: 0))
    nRight.closeSubpath()
    cg.setFillColor(cgColor(northDark))
    cg.addPath(nRight)
    cg.fillPath()

    let sLeft = CGMutablePath()
    sLeft.move(to: CGPoint(x: 0, y: -length))
    sLeft.addLine(to: CGPoint(x: -halfWidth, y: 0))
    sLeft.addLine(to: CGPoint(x: 0, y: 0))
    sLeft.closeSubpath()
    cg.setFillColor(cgColor(southLight))
    cg.addPath(sLeft)
    cg.fillPath()

    let sRight = CGMutablePath()
    sRight.move(to: CGPoint(x: 0, y: -length))
    sRight.addLine(to: CGPoint(x: halfWidth, y: 0))
    sRight.addLine(to: CGPoint(x: 0, y: 0))
    sRight.closeSubpath()
    cg.setFillColor(cgColor(southDark))
    cg.addPath(sRight)
    cg.fillPath()

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -3), blur: 8, color: cgColor(0x000000, 0.35))
    cg.setFillColor(cgColor(0x0F172A))
    cg.fillEllipse(in: CGRect(x: -22, y: -22, width: 44, height: 44))
    cg.setFillColor(cgColor(0x38BDF8))
    cg.fillEllipse(in: CGRect(x: -10, y: -10, width: 20, height: 20))
    cg.restoreGState()

    cg.restoreGState()
}

let rep = renderCanvas { cg in
    let squircle = drawSquircleBase(
        cg,
        topColor: 0x0EA5E9,
        midColor: 0x1D4ED8,
        bottomColor: 0x0B1120,
        glowColor: 0x38BDF8,
        glowCenter: CGPoint(x: 512, y: 760)
    )
    cg.saveGState()
    cg.addPath(squircle)
    cg.clip()

    let center = CGPoint(x: 512, y: 512)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -16), blur: 36, color: cgColor(0x000000, 0.42))
    let dialRect = CGRect(x: center.x - 320, y: center.y - 320, width: 640, height: 640)
    cg.setFillColor(cgColor(0x0F172A, 0.52))
    cg.fillEllipse(in: dialRect)
    cg.restoreGState()

    cg.saveGState()
    cg.addEllipse(in: dialRect)
    cg.clip()
    let dialGrad = CGGradient(
        colorsSpace: space,
        colors: [cgColor(0x1E3A8A, 0.72), cgColor(0x090D16, 0.88)] as CFArray,
        locations: [0.0, 1.0]
    )!
    cg.drawLinearGradient(dialGrad, start: CGPoint(x: 512, y: 832), end: CGPoint(x: 512, y: 192), options: [])
    cg.restoreGState()

    cg.setStrokeColor(cgColor(0x7DD3FC, 0.45))
    cg.setLineWidth(4)
    cg.strokeEllipse(in: dialRect)

    let orbits: [(rx: CGFloat, ry: CGFloat, deg: CGFloat, color: UInt32, dotAngle: CGFloat)] = [
        (255, 108, -28, 0x38BDF8, 0.55),
        (255, 108, 32, 0x818CF8, 2.45),
        (255, 108, 92, 0x34D399, 4.20)
    ]
    for o in orbits {
        cg.saveGState()
        cg.translateBy(x: center.x, y: center.y)
        cg.rotate(by: o.deg * .pi / 180.0)
        cg.setStrokeColor(cgColor(o.color, 0.52))
        cg.setLineWidth(5)
        cg.strokeEllipse(in: CGRect(x: -o.rx, y: -o.ry, width: o.rx * 2, height: o.ry * 2))

        let nx = cos(o.dotAngle) * o.rx
        let ny = sin(o.dotAngle) * o.ry
        cg.setShadow(offset: .zero, blur: 14, color: cgColor(o.color, 0.95))
        cg.setFillColor(cgColor(o.color, 1.0))
        cg.fillEllipse(in: CGRect(x: nx - 11, y: ny - 11, width: 22, height: 22))
        cg.setFillColor(cgColor(0xFFFFFF, 0.9))
        cg.fillEllipse(in: CGRect(x: nx - 5, y: ny - 5, width: 10, height: 10))
        cg.restoreGState()
    }

    drawCompassTicks(cg, center: center, radius: 296, count: 72, color: 0xE0F2FE, baseAlpha: 0.55)
    drawCompassNeedle(cg, center: center, length: 248, halfWidth: 46, angleDegrees: -42)
    cg.restoreGState()
}

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG 编码失败\n".utf8))
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
} catch {
    FileHandle.standardError.write(Data("写入 \(CommandLine.arguments[1]) 失败：\(error)\n".utf8))
    exit(1)
}
