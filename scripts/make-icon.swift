// Renders Resources/AppIcon.icns: a calendar page with a blue header, a day timeline of
// colored event blocks and a red "now" line. Run: swift scripts/make-icon.swift
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = s / 1024  // design on a 1024 grid; macOS icon body is inset ~100px

    // Body: rounded square with soft shadow
    let body = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28 * u
    shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185 * u, yRadius: 185 * u)
    color(0xFFFFFF).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    bodyPath.addClip()

    // Blue header band with gradient
    let header = NSRect(x: body.minX, y: body.maxY - 230 * u, width: body.width, height: 230 * u)
    NSGradient(starting: color(0x4285F4), ending: color(0x1A73E8))!.draw(in: header, angle: -90)

    // Binder rings
    for x in [330.0, 694.0] {
        let ring = NSRect(x: CGFloat(x) * u - 22 * u, y: header.minY + 150 * u, width: 44 * u, height: 44 * u)
        color(0xFFFFFF, 0.9).setFill()
        NSBezierPath(ovalIn: ring).fill()
    }
    // Header label: "יומן"
    let label = "יומן" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 92 * u, weight: .heavy), .foregroundColor: NSColor.white,
    ]
    let ls = label.size(withAttributes: attrs)
    label.draw(at: NSPoint(x: body.midX - ls.width / 2, y: header.minY + 28 * u), withAttributes: attrs)

    // Hour lines
    let left = body.minX + 120 * u, right = body.maxX - 70 * u
    for i in 0..<5 {
        let y = header.minY - 90 * u - CGFloat(i) * 110 * u
        color(0xDADCE0).setFill()
        NSRect(x: left - 40 * u, y: y, width: right - left + 40 * u, height: 5 * u).fill()
        color(0xBDC1C6).setFill()
        NSBezierPath(ovalIn: NSRect(x: body.minX + 60 * u, y: y - 9 * u, width: 22 * u, height: 22 * u)).fill()
    }

    // Event blocks (Google palette)
    func block(_ y: CGFloat, _ h: CGFloat, _ x: CGFloat, _ c: NSColor) {
        let r = NSRect(x: left + x * u, y: header.minY - y * u - h * u, width: right - left - x * u, height: h * u)
        c.setFill()
        NSBezierPath(roundedRect: r, xRadius: 26 * u, yRadius: 26 * u).fill()
        color(0xFFFFFF, 0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX + 28 * u, y: r.maxY - 52 * u, width: min(260 * u, r.width * 0.55), height: 22 * u),
                     xRadius: 11 * u, yRadius: 11 * u).fill()
    }
    block(110, 150, 0, color(0x1A73E8))
    block(300, 240, 0, color(0xF4511E))
    block(390, 120, 110, color(0x0B8043))

    // Now line
    let ny = header.minY - 470 * u
    color(0xEA4335).setFill()
    NSRect(x: left - 20 * u, y: ny, width: right - left + 20 * u, height: 12 * u).fill()
    NSBezierPath(ovalIn: NSRect(x: left - 48 * u, y: ny - 22 * u, width: 56 * u, height: 56 * u)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try! render(pt * scale).write(to: iconset.appendingPathComponent(name))
}
try! render(1024).write(to: root.appendingPathComponent("Resources/AppIcon-preview.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
