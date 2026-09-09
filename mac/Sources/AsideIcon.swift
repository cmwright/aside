import AppKit

/// Aside's glyph: a text cursor with two sound arcs to its right — voice arriving at the
/// cursor. Drawn in code as a template image so it follows the menu bar's appearance and
/// stays crisp at any scale. Each dictation state gets its own variant.
enum AsideIcon {
    static let menuBarSize = NSSize(width: 18, height: 18)

    static func menuBarImage(for state: DictationState) -> NSImage {
        let image = NSImage(size: menuBarSize, flipped: false) { rect in
            draw(state: state, in: rect, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Aside, \(state.menuTitle)"
        return image
    }

    /// Shared with the app-icon generator script; keep the geometry in points on an 18 pt grid.
    static func draw(state: DictationState, in rect: NSRect, color: NSColor) {
        let scale = rect.width / 18
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        color.setStroke()
        color.setFill()

        // I-beam cursor.
        let beamX: CGFloat = 5
        let beam = NSBezierPath()
        beam.lineWidth = 1.6 * scale
        beam.lineCapStyle = .round
        beam.move(to: pt(beamX, 3)); beam.line(to: pt(beamX, 15))
        beam.move(to: pt(beamX - 2, 15)); beam.line(to: pt(beamX + 2, 15))
        beam.move(to: pt(beamX - 2, 3)); beam.line(to: pt(beamX + 2, 3))
        beam.stroke()

        let origin = pt(beamX + 1.5, 9)
        func arcs(radii: [CGFloat], width: CGFloat) {
            for radius in radii {
                let path = NSBezierPath()
                path.lineWidth = width * scale
                path.lineCapStyle = .round
                path.appendArc(withCenter: origin, radius: radius * scale, startAngle: -38, endAngle: 38)
                path.stroke()
            }
        }
        func dot(_ x: CGFloat, _ y: CGFloat, radius: CGFloat) {
            let r = radius * scale
            let center = pt(x, y)
            NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()
        }

        switch state {
        case .idle:
            arcs(radii: [4.5, 8], width: 1.6)
        case .recording:
            arcs(radii: [4.5, 8], width: 2.2)
            dot(beamX + 3.4, 9, radius: 1.3)
        case .processing:
            dot(9.5, 9, radius: 1.2)
            dot(12.5, 9, radius: 1.2)
            dot(15.5, 9, radius: 1.2)
        case .failed:
            let mark = NSBezierPath()
            mark.lineWidth = 2 * scale
            mark.lineCapStyle = .round
            mark.move(to: pt(13, 15)); mark.line(to: pt(13, 8))
            mark.stroke()
            dot(13, 4, radius: 1.2)
        }
    }
}
