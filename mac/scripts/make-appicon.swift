#!/usr/bin/env swift
// Renders Resources/AppIcon.icns from the same glyph the menu bar uses (AsideIcon.draw, idle).
// Usage: cd mac && swift scripts/make-appicon.swift
import AppKit

func drawGlyph(in rect: NSRect, color: NSColor) {
    let scale = rect.width / 18
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * scale, y: rect.minY + y * scale) }
    color.setStroke(); color.setFill()
    let beamX: CGFloat = 5
    let beam = NSBezierPath(); beam.lineWidth = 1.6 * scale; beam.lineCapStyle = .round
    beam.move(to: pt(beamX, 3)); beam.line(to: pt(beamX, 15))
    beam.move(to: pt(beamX - 2, 15)); beam.line(to: pt(beamX + 2, 15))
    beam.move(to: pt(beamX - 2, 3)); beam.line(to: pt(beamX + 2, 3))
    beam.stroke()
    let origin = pt(beamX + 1.5, 9)
    for radius in [4.5, 8] as [CGFloat] {
        let p = NSBezierPath(); p.lineWidth = 1.6 * scale; p.lineCapStyle = .round
        p.appendArc(withCenter: origin, radius: radius * scale, startAngle: -38, endAngle: 38)
        p.stroke()
    }
}

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(px)
    let inset = size * 0.10   // macOS icon grid: artwork inside ~80% of the canvas
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let bg = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.16, blue: 0.55, alpha: 1),
                              ending: NSColor(calibratedRed: 0.45, green: 0.30, blue: 0.85, alpha: 1))!
    gradient.draw(in: bg, angle: -60)
    let g = tile.width * 0.58
    let glyphRect = NSRect(x: tile.midX - g / 2 + g * 0.02, y: tile.midY - g / 2, width: g, height: g)
    drawGlyph(in: glyphRect, color: .white)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let data = render(px).representation(using: .png, properties: [:])!
    try! data.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
try! fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
task.launch(); task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
exit(task.terminationStatus)
