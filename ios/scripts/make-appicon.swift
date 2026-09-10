#!/usr/bin/env swift
// Renders App/Assets.xcassets/AppIcon.appiconset/icon-1024.png from the same glyph the Mac
// app uses (mac/scripts/make-appicon.swift), full-bleed: iOS applies its own corner mask.
// Usage: cd ios && swift scripts/make-appicon.swift
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

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let canvas = NSRect(x: 0, y: 0, width: px, height: px)
let gradient = NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.16, blue: 0.55, alpha: 1),
                          ending: NSColor(calibratedRed: 0.45, green: 0.30, blue: 0.85, alpha: 1))!
gradient.draw(in: canvas, angle: -60)
let g = CGFloat(px) * 0.58
let glyphRect = NSRect(x: canvas.midX - g / 2 + g * 0.02, y: canvas.midY - g / 2, width: g, height: g)
drawGlyph(in: glyphRect, color: .white)
NSGraphicsContext.restoreGraphicsState()
let out = "App/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
