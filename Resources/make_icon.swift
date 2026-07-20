import Foundation
import AppKit
import CoreGraphics

let outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("AppIcon.iconset", isDirectory: true)

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xff) / 255
    let g = CGFloat((hex >> 8) & 0xff) / 255
    let b = CGFloat(hex & 0xff) / 255
    return CGColor(red: r, green: g, blue: b, alpha: alpha)
}

func path(_ points: [CGPoint], closed: Bool = true) -> CGMutablePath {
    let p = CGMutablePath()
    guard let first = points.first else { return p }
    p.move(to: first)
    for point in points.dropFirst() { p.addLine(to: point) }
    if closed { p.closeSubpath() }
    return p
}

func squirclePath(in rect: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
    let r = min(radius, min(w, h) * 0.5)
    let k: CGFloat = 0.82
    p.move(to: CGPoint(x: x + r, y: y))
    p.addLine(to: CGPoint(x: x + w - r, y: y))
    p.addCurve(to: CGPoint(x: x + w, y: y + r), control1: CGPoint(x: x + w - r * k, y: y), control2: CGPoint(x: x + w, y: y + r * k))
    p.addLine(to: CGPoint(x: x + w, y: y + h - r))
    p.addCurve(to: CGPoint(x: x + w - r, y: y + h), control1: CGPoint(x: x + w, y: y + h - r * k), control2: CGPoint(x: x + w - r * k, y: y + h))
    p.addLine(to: CGPoint(x: x + r, y: y + h))
    p.addCurve(to: CGPoint(x: x, y: y + h - r), control1: CGPoint(x: x + r * k, y: y + h), control2: CGPoint(x: x, y: y + h - r * k))
    p.addLine(to: CGPoint(x: x, y: y + r))
    p.addCurve(to: CGPoint(x: x + r, y: y), control1: CGPoint(x: x, y: y + r * k), control2: CGPoint(x: x + r * k, y: y))
    p.closeSubpath()
    return p
}

func drawIcon(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                isPlanar: false, colorSpaceName: .deviceRGB,
                                bitmapFormat: [], bytesPerRow: size * 4, bitsPerPixel: 32)!
    let ctx = CGContext(data: rep.bitmapData, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: rep.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    let canvas = CGRect(x: 52, y: 52, width: 920, height: 920)
    let bgPath = squirclePath(in: canvas, radius: 215)
    ctx.addPath(bgPath)
    ctx.clip()
    let bgGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0xF4FBE8), color(0xE4F3CE)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 130, y: 920), end: CGPoint(x: 880, y: 100), options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    ctx.setShadow(offset: CGSize(width: 0, height: -13), blur: 26, color: color(0x6E9C45, alpha: 0.24))
    ctx.setStrokeColor(color(0xFFFFFF, alpha: 0.7)); ctx.setLineWidth(7); ctx.addPath(bgPath); ctx.strokePath()
    ctx.restoreGState()

    // Soft ground shadow.
    ctx.saveGState()
    ctx.setFillColor(color(0x477B2B, alpha: 0.18)); ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 32, color: color(0x477B2B, alpha: 0.22))
    ctx.fillEllipse(in: CGRect(x: 185, y: 178, width: 660, height: 150)); ctx.restoreGState()

    // Pod silhouette, rotated diagonally from lower-left to upper-right.
    ctx.saveGState(); ctx.translateBy(x: 512, y: 515); ctx.rotate(by: -0.29)
    let pod = CGMutablePath(); pod.move(to: CGPoint(x: -350, y: -40))
    pod.addCurve(to: CGPoint(x: 316, y: 18), control1: CGPoint(x: -170, y: -180), control2: CGPoint(x: 185, y: -154))
    pod.addCurve(to: CGPoint(x: 352, y: 100), control1: CGPoint(x: 356, y: 46), control2: CGPoint(x: 355, y: 74))
    pod.addCurve(to: CGPoint(x: 264, y: 172), control1: CGPoint(x: 340, y: 139), control2: CGPoint(x: 302, y: 165))
    pod.addCurve(to: CGPoint(x: -308, y: 125), control1: CGPoint(x: 58, y: 218), control2: CGPoint(x: -230, y: 210))
    pod.addCurve(to: CGPoint(x: -350, y: -40), control1: CGPoint(x: -357, y: 70), control2: CGPoint(x: -366, y: -2))
    pod.closeSubpath()
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 22, color: color(0x2F6C24, alpha: 0.38)); ctx.addPath(pod); ctx.setFillColor(color(0x4D942D)); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(pod); ctx.clip()
    let podGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0xA8E063), color(0x56A02F)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(podGradient, start: CGPoint(x: -320, y: 180), end: CGPoint(x: 300, y: -120), options: [])
    ctx.setFillColor(color(0xD9F59A, alpha: 0.32)); ctx.fillEllipse(in: CGRect(x: -260, y: 40, width: 330, height: 80))
    ctx.setStrokeColor(color(0xD4F28F, alpha: 0.82)); ctx.setLineWidth(17); ctx.addPath(pod); ctx.strokePath(); ctx.restoreGState()
    ctx.setStrokeColor(color(0x397F28, alpha: 0.92)); ctx.setLineWidth(11); ctx.addPath(pod); ctx.strokePath()

    // Three plump beans emerging from the pod.
    let beans: [(CGFloat, CGFloat, CGFloat)] = [(-155, 36, 103), (0, 55, 116), (156, 74, 101)]
    for (x, y, r) in beans {
        let beanRect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 1.84)
        ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 13, color: color(0x2C6C24, alpha: 0.34)); ctx.setFillColor(color(0x71B83B)); ctx.fillEllipse(in: beanRect); ctx.restoreGState()
        ctx.saveGState(); ctx.addEllipse(in: beanRect); ctx.clip()
        let beanGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0xB3E96A), color(0x4E9A2D)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(beanGradient, start: CGPoint(x: x - r, y: y + r), end: CGPoint(x: x + r, y: y - r), options: [])
        ctx.setFillColor(color(0xE9FFB9, alpha: 0.62)); ctx.fillEllipse(in: CGRect(x: x - r * 0.55, y: y + r * 0.42, width: r * 0.72, height: r * 0.30)); ctx.restoreGState()
        ctx.setStrokeColor(color(0x3D8429, alpha: 0.78)); ctx.setLineWidth(7); ctx.strokeEllipse(in: beanRect)
    }

    // Face, kept simple for small-size readability.
    ctx.setFillColor(color(0x245D24)); ctx.fillEllipse(in: CGRect(x: -78, y: 35, width: 22, height: 28)); ctx.fillEllipse(in: CGRect(x: 56, y: 35, width: 22, height: 28))
    let smile = CGMutablePath(); smile.move(to: CGPoint(x: -35, y: 26)); smile.addCurve(to: CGPoint(x: 37, y: 26), control1: CGPoint(x: -20, y: -4), control2: CGPoint(x: 20, y: -4)); ctx.addPath(smile); ctx.setStrokeColor(color(0x245D24)); ctx.setLineWidth(9); ctx.setLineCap(.round); ctx.strokePath()

    // Stem and fuzzy tip details.
    ctx.setStrokeColor(color(0x397F28)); ctx.setLineWidth(16); ctx.setLineCap(.round); ctx.move(to: CGPoint(x: 340, y: 95)); ctx.addLine(to: CGPoint(x: 391, y: 151)); ctx.strokePath()
    ctx.setFillColor(color(0x8CC84B)); ctx.fillEllipse(in: CGRect(x: 380, y: 140, width: 42, height: 30))
    ctx.setStrokeColor(color(0x6B9F38, alpha: 0.8)); ctx.setLineWidth(4)
    for i in 0..<5 { let dx = CGFloat(i * 9 - 18); ctx.move(to: CGPoint(x: 399 + dx, y: 155)); ctx.addLine(to: CGPoint(x: 394 + dx, y: 172 + CGFloat(i % 2) * 5)) }; ctx.strokePath()
    ctx.restoreGState()
    return rep
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (name, pixelSize) in sizes {
    let rep = drawIcon(size: pixelSize)
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: outputDirectory.appendingPathComponent(name))
    print("wrote \(name) (\(pixelSize)x\(pixelSize))")
}
