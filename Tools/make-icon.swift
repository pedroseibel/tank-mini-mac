// make-icon: draws the app icon and writes AppIcon.iconset (all sizes) plus a 1024 px preview.
// Usage: swift Tools/make-icon.swift <output-folder>
// Then:  iconutil -c icns <output-folder>/AppIcon.iconset -o Resources/AppIcon.icns
//
// The icon is the app's own knob: a 270 degree track with an amber value arc and a
// raised cap, on a graphite rounded square that follows the macOS icon grid
// (824 pt shape in a 1024 pt canvas).
import AppKit
import CoreGraphics
import Foundation

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

/// Draw the icon into a `pixels` x `pixels` bitmap. All geometry is in 1024-unit space.
func render(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    let center = CGPoint(x: 512, y: 512)

    // Shape with the standard soft drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x1B1C20))
    ctx.fillPath()
    ctx.restoreGState()

    // Graphite background
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0x3C3F47)), (1, color(0x17181C))]),
                           start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    // Soft glow behind the knob so the cap separates from the background
    ctx.drawRadialGradient(gradient([(0, color(0xFFFFFF, 0.10)), (1, color(0xFFFFFF, 0))]),
                           startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 560), endRadius: 420, options: [])
    ctx.restoreGState()

    // Hairline highlight along the top edge
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setLineWidth(4)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.22)), (0.5, color(0xFFFFFF, 0.02))]),
                           start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    ctx.restoreGState()

    // Track: 270 degrees, open at the bottom. Angles are counter-clockwise from +x.
    let trackRadius: CGFloat = 262
    let trackWidth: CGFloat = 46
    let startAngle = CGFloat.pi * 1.25 // lower left
    let endAngle = -CGFloat.pi * 0.25 // lower right
    let fraction: CGFloat = 0.72
    let valueAngle = startAngle - (startAngle - endAngle) * fraction

    ctx.setLineCap(.round)
    ctx.setLineWidth(trackWidth)
    ctx.addArc(center: center, radius: trackRadius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
    ctx.setStrokeColor(color(0xFFFFFF, 0.11))
    ctx.strokePath()

    // Value arc, amber to orange, with a faint glow
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 26 * scale, color: color(0xFF8A1F, 0.55))
    ctx.addArc(center: center, radius: trackRadius, startAngle: startAngle, endAngle: valueAngle, clockwise: true)
    ctx.setLineWidth(trackWidth)
    ctx.setStrokeColor(color(0xFF9F2E))
    ctx.strokePath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addArc(center: center, radius: trackRadius, startAngle: startAngle, endAngle: valueAngle, clockwise: true)
    ctx.setLineWidth(trackWidth)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xFFC14D)), (1, color(0xFF6B2C))]),
                           start: CGPoint(x: 250, y: 330), end: CGPoint(x: 774, y: 700), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Knob cap, raised
    let capRadius: CGFloat = 178
    let cap = CGRect(x: center.x - capRadius, y: center.y - capRadius, width: capRadius * 2, height: capRadius * 2)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * scale), blur: 36 * scale, color: color(0x000000, 0.55))
    ctx.addEllipse(in: cap)
    ctx.setFillColor(color(0xD9DBE0))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: cap)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xFBFBFC)), (1, color(0xB9BCC4))]),
                           start: CGPoint(x: 512, y: cap.maxY), end: CGPoint(x: 512, y: cap.minY), options: [])
    ctx.restoreGState()
    // Bevel ring
    ctx.addEllipse(in: cap.insetBy(dx: 3, dy: 3))
    ctx.setLineWidth(6)
    ctx.setStrokeColor(color(0xFFFFFF, 0.55))
    ctx.strokePath()
    // Inner face, very slightly dished
    let face = cap.insetBy(dx: 26, dy: 26)
    ctx.saveGState()
    ctx.addEllipse(in: face)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xDCDEE3)), (1, color(0xF4F5F7))]),
                           start: CGPoint(x: 512, y: face.maxY), end: CGPoint(x: 512, y: face.minY), options: [])
    ctx.restoreGState()

    // Indicator, pointing at the end of the value arc
    let inner: CGFloat = 62
    let outer: CGFloat = 132
    ctx.setLineCap(.round)
    ctx.setLineWidth(28)
    ctx.setStrokeColor(color(0x26282D))
    ctx.move(to: CGPoint(x: center.x + cos(valueAngle) * inner, y: center.y + sin(valueAngle) * inner))
    ctx.addLine(to: CGPoint(x: center.x + cos(valueAngle) * outer, y: center.y + sin(valueAngle) * outer))
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let iconset = out.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, factor) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try writePNG(render(pixels: points * factor), to: iconset.appendingPathComponent(name))
}
try writePNG(render(pixels: 1024), to: out.appendingPathComponent("icon-preview.png"))
print("wrote \(iconset.path)")
