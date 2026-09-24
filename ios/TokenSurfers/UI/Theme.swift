import SwiftUI

/// The look of misc/3.MP4: cut paper on sunset orange, Claude-orange splat,
/// fat stroked captions in white + highlighter yellow, a navy code screen.
enum Theme {
    static let orange = Color(hex: 0xF4703A)      // sunburst ground
    static let orangeDeep = Color(hex: 0xE85B26)
    static let splat = Color(hex: 0xE9804F)       // the mascot
    static let splatDark = Color(hex: 0xC9602F)
    static let yellow = Color(hex: 0xFFD53A)      // caption highlight
    static let cream = Color(hex: 0xFFF6EA)       // paper
    static let paper = Color(hex: 0xFBF4EA)
    static let ink = Color(hex: 0x17131F)
    static let ink2 = Color(hex: 0x5B5566)
    static let navy = Color(hex: 0x1C1B34)        // code screen
    static let navy2 = Color(hex: 0x262546)
    static let lavender = Color(hex: 0xC9C3F2)
    static let pink = Color(hex: 0xF7A8C8)
    static let red = Color(hex: 0xF0453A)
    static let purple = Color(hex: 0x4B2FA8)      // tokenur night
    static let sky = Color(hex: 0x4FA6E0)         // contextino sea
    static let mint = Color(hex: 0x57D19A)

    static func anton(_ size: CGFloat) -> Font { .custom("Anton-Regular", size: size) }
    static func black(_ size: CGFloat) -> Font { .custom("Montserrat-Black", size: size) }
    static func heavy(_ size: CGFloat) -> Font { .custom("Montserrat-ExtraBold", size: size) }
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// The TikTok caption treatment: a thick dark outline and a hard drop shadow.
struct StrokedText: View {
    let text: String
    var font: Font
    var color: Color = .white
    var stroke: CGFloat = 3

    var body: some View {
        let base = Text(text).font(font)
        ZStack {
            // Eight offset copies make a solid outline that survives any font.
            ForEach(0..<8, id: \.self) { i in
                let a = Double(i) / 8 * 2 * .pi
                base.foregroundStyle(Theme.ink)
                    .offset(x: cos(a) * stroke, y: sin(a) * stroke)
            }
            base.foregroundStyle(color)
        }
        .shadow(color: Theme.ink.opacity(0.9), radius: 0, x: 0, y: stroke * 1.2)
    }
}

/// A caption line whose words are white except the highlighted ones (yellow).
struct CaptionLine: View {
    let words: [String]
    let highlight: Set<Int>
    var size: CGFloat
    var font: (CGFloat) -> Font = Theme.black

    var body: some View {
        HStack(spacing: size * 0.22) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                StrokedText(text: w, font: font(size),
                            color: highlight.contains(i) ? Theme.yellow : .white,
                            stroke: max(2, size * 0.09))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.4)
    }
}

/// Paper grain, drawn once per size: faint specks and fibres over any fill.
struct PaperGrain: View {
    var opacity: Double = 0.10
    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRandom(seed: 7)
            let n = Int(size.width * size.height / 90)
            for _ in 0..<n {
                let x = rng.unit() * size.width, y = rng.unit() * size.height
                let r = 0.4 + rng.unit() * 0.9
                let dark = rng.unit() < 0.55
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                         with: .color(dark ? .black.opacity(0.5) : .white.opacity(0.8)))
            }
            for _ in 0..<(n / 40) {
                let x = rng.unit() * size.width, y = rng.unit() * size.height
                var p = Path()
                p.move(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: x + (rng.unit() - 0.5) * 14, y: y + (rng.unit() - 0.5) * 3))
                ctx.stroke(p, with: .color(.white.opacity(0.6)), lineWidth: 0.6)
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
        .drawingGroup()
    }
}

/// Rotating sunburst rays (the AITA card background, the "absolutely right" moment).
struct Sunburst: View {
    var a: Color = Theme.orange
    var b: Color = Theme.orangeDeep
    var rays = 16
    var spin = true

    var body: some View {
        TimelineView(.animation(paused: !spin)) { tl in
            Canvas { ctx, size in
                let t = spin ? tl.date.timeIntervalSinceReferenceDate : 0
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(a))
                let c = CGPoint(x: size.width / 2, y: size.height * 0.42)
                let R = hypot(size.width, size.height)
                let step = 2 * Double.pi / Double(rays)
                for i in 0..<rays {
                    let a0 = Double(i) * step + t * 0.08
                    var p = Path()
                    p.move(to: c)
                    p.addLine(to: CGPoint(x: c.x + cos(a0) * R, y: c.y + sin(a0) * R))
                    p.addLine(to: CGPoint(x: c.x + cos(a0 + step / 2) * R, y: c.y + sin(a0 + step / 2) * R))
                    p.closeSubpath()
                    ctx.fill(p, with: .color(b))
                }
            }
        }
    }
}

/// Paper card: cream fill, white torn-ish edge, soft drop shadow.
struct PaperCard: ViewModifier {
    var fill: Color = Theme.paper
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .overlay(PaperGrain(opacity: 0.06).clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.9), lineWidth: 2))
                    .shadow(color: .black.opacity(0.22), radius: 0, x: 0, y: 4)
            )
    }
}

extension View {
    func paperCard(_ fill: Color = Theme.paper, radius: CGFloat = 18) -> some View {
        modifier(PaperCard(fill: fill, radius: radius))
    }
}

/// Squishy press feedback for chunky buttons.
struct SquishStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .offset(y: configuration.isPressed ? 2 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// A chunky pill button in the video's sticker style.
struct ChunkyButton: View {
    let title: String
    var fill: Color = Theme.splat
    var textColor: Color = .white
    var height: CGFloat = 52
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.black(height * 0.34))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(
                    Capsule().fill(fill)
                        .overlay(Capsule().strokeBorder(Theme.ink, lineWidth: 2.5))
                        .background(Capsule().fill(Theme.ink).offset(y: 4))
                )
        }
        .buttonStyle(SquishStyle())
    }
}

/// Deterministic randomness for drawings and the game.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func nextUInt() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func next() -> UInt64 { nextUInt() }
    mutating func unit() -> Double { Double(nextUInt() % 1_000_000) / 1_000_000 }
    mutating func int(_ n: Int) -> Int { Int(nextUInt() % UInt64(max(n, 1))) }
}
