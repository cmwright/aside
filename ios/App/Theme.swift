import SwiftUI

/// The iPhone app's look: dark surfaces with a faint violet cast, the icon's violet as the
/// one brand colour, a hot red for live recording, and nothing else. Condensed display type
/// for titles and the word mark, a mono face for measurements and status labels, the system
/// font for reading. Compiled into the app and the keyboard extension.
enum Theme {
    static let bg = Color(hex: 0x0F0F13)
    static let surface = Color(hex: 0x17171D)
    static let surface2 = Color(hex: 0x1F1F27)
    static let line = Color(hex: 0x2A2A34)
    static let line2 = Color(hex: 0x34343F)
    static let text = Color(hex: 0xF1F0F5)
    static let text2 = Color(hex: 0x9C9AAA)
    static let text3 = Color(hex: 0x64626F)
    static let violet = Color(hex: 0x8B6CF0)
    static let violetLight = Color(hex: 0x9F84F5)
    static let violetDeep = Color(hex: 0x5F44C4)
    static let live = Color(hex: 0xFF5C4D)
    static let liveDim = Color(hex: 0x5A2A28)
    static let amber = Color(hex: 0xF2B544)

    /// Barlow Condensed, bundled (OFL). Titles and the word mark.
    static func display(_ size: CGFloat) -> Font { .custom("BarlowCondensed-SemiBold", size: size) }
    /// IBM Plex Mono, bundled (OFL). Timings, counts, status labels.
    static func mono(_ size: CGFloat, medium: Bool = false) -> Font {
        .custom(medium ? "IBMPlexMono-Medium" : "IBMPlexMono-Regular", size: size)
    }

    static let violetDisc = LinearGradient(colors: [violetLight, violet, violetDeep],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
    static let liveDisc = RadialGradient(colors: [Color(hex: 0xFF7A6B), live, Color(hex: 0xC63C30)],
                                         center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 120)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Small uppercase mono caption: the instrument label used for every measurement.
struct MonoLabel: View {
    var text: String
    var color: Color = Theme.text3
    var size: CGFloat = 11

    init(_ text: String, color: Color = Theme.text3, size: CGFloat = 11) {
        self.text = text
        self.color = color
        self.size = size
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.mono(size))
            .tracking(size * 0.08)
            .foregroundStyle(color)
    }
}

/// A list section header in the same voice. `textCase(nil)` stops List re-casing it.
struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { MonoLabel(text, color: Theme.text2).textCase(nil) }
}

/// Aside's mark: an I-beam cursor with two sound arcs to its right, voice arriving at the
/// cursor. Same 18-unit geometry as `AsideIcon.swift` on the Mac. Arcs are polylines so the
/// shape never depends on which way a platform thinks "clockwise" goes.
struct AsideGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 18
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: pt(5, 3)); path.addLine(to: pt(5, 15))
        path.move(to: pt(3, 3)); path.addLine(to: pt(7, 3))
        path.move(to: pt(3, 15)); path.addLine(to: pt(7, 15))
        let center = pt(6.5, 9)
        for radius in [4.5, 8] as [CGFloat] {
            let steps = 24
            for i in 0...steps {
                let angle = (-38 + 76 * Double(i) / Double(steps)) * .pi / 180
                let p = CGPoint(x: center.x + radius * s * cos(angle), y: center.y + radius * s * sin(angle))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
        return path
    }
}

struct GlyphView: View {
    var size: CGFloat = 24
    var color: Color = Theme.text
    var weight: CGFloat = 1.6
    /// The recording variant: heavier strokes and a dot at the cursor.
    var live = false

    var body: some View {
        AsideGlyphShape()
            .stroke(color, style: StrokeStyle(lineWidth: (live ? 2.2 : weight) * size / 18, lineCap: .round, lineJoin: .round))
            .overlay {
                if live {
                    Circle().fill(color)
                        .frame(width: size * 2.6 / 18, height: size * 2.6 / 18)
                        .position(x: size * 8.4 / 18, y: size * 9 / 18)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The word mark: glyph plus ASIDE in tracked condensed caps.
struct Wordmark: View {
    var height: CGFloat = 18
    var color: Color = Theme.text
    var glyphColor: Color = Theme.violet

    var body: some View {
        HStack(spacing: height * 0.45) {
            GlyphView(size: height + 4, color: glyphColor)
            Text("ASIDE")
                .font(Theme.display(height * 1.22))
                .tracking(height * 1.22 * 0.14)
                .foregroundStyle(color)
                .padding(.top, 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aside")
    }
}

/// The segmented meter ring around the mic control. Idle it is a quiet dial; live, the
/// segments light up clockwise from the top with the input level.
struct MeterRing: View {
    var size: CGFloat
    var live = false
    /// 0...1, only read while live. Animatable, so a level change sweeps the segments.
    var level: Float = 0

    private static let segments = 48

    var body: some View {
        Canvas { context, _ in
            let radius = size / 2 - 6
            let center = CGPoint(x: size / 2, y: size / 2)
            let lit = Int((CGFloat(max(0, min(1, level))) * CGFloat(MeterRing.segments)).rounded())
            for i in 0..<MeterRing.segments {
                let a0 = (-90 + Double(i) * 360 / Double(MeterRing.segments) + 1.6) * .pi / 180
                let a1 = (-90 + Double(i + 1) * 360 / Double(MeterRing.segments) - 1.6) * .pi / 180
                var path = Path()
                for (n, a) in [a0, (a0 + a1) / 2, a1].enumerated() {
                    let p = CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
                    if n == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                let color: Color = live ? (i < lit ? Theme.live : Theme.liveDim) : Theme.line2
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .butt))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension MeterRing: @preconcurrency Animatable {
    var animatableData: Float {
        get { level }
        set { level = newValue }
    }
}

/// The level-history strip: one thin bar per recent chunk of audio, newest on the right.
struct LevelStrip: View {
    var values: [Float]
    var color: Color
    var count = 40
    var height: CGFloat = 44

    var body: some View {
        let padded = Array(repeating: Float(0), count: max(0, count - values.count)) + values.suffix(count)
        HStack(spacing: 3) {
            ForEach(Array(padded.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(3, height * CGFloat(value)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A plain dark panel, so the screens look like one app.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.line))
    }
}

/// A capsule with a status dot and a mono label; the session indicator and small actions.
/// The label swaps digits in place (a countdown), and a `pulsing` dot breathes.
struct Pill: View {
    var text: String
    var dot: Color?
    var systemImage: String?
    var textColor: Color = Theme.text2
    var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            if let dot {
                Circle().fill(dot).frame(width: 7, height: 7)
                    .overlay {
                        if pulsing {
                            Circle().stroke(dot, lineWidth: 1.5)
                                .phaseAnimator([0.0, 1.0]) { view, phase in
                                    view.scaleEffect(1 + phase * 1.6).opacity(1 - phase)
                                } animation: { _ in .easeOut(duration: 1.6) }
                        }
                    }
                    .shadow(color: dot.opacity(pulsing ? 0.9 : 0.5), radius: 4)
            }
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 12, weight: .medium)).foregroundStyle(textColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            MonoLabel(text, color: textColor)
                .contentTransition(.numericText(countsDown: true))
        }
        .animation(.snappy(duration: 0.3), value: text)
        .animation(.easeInOut(duration: 0.3), value: pulsing)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line))
        .contentShape(Capsule())
    }
}

/// Press feedback for the big controls: a quick, springy shrink while the finger is down.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.95

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(duration: 0.25, bounce: 0.35), value: configuration.isPressed)
    }
}

extension View {
    /// A List or Form on the app's background instead of the system grouped grey.
    func themedList() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Theme.bg)
    }
}
