import SwiftUI
import UIKit

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

    static func color(_ hex: UInt32) -> Color { Color(hex: hex) }

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
        // One layer per label. It was nine stacked Texts plus a CA shadow pass
        // (an offscreen render of the group) that the system re-rendered every
        // time a score or a line count changed; with a dozen of them on screen
        // the phone's display clocked down to 30 fps during a build (2026-09-26).
        // The hidden Text gives the layout; the canvas draws outline, hard
        // shadow and fill (eight offset copies make a solid outline in any font).
        base.hidden()
            .padding(.horizontal, stroke * 1.5)
            .padding(.vertical, stroke * 2.2)
            .overlay {
                Canvas { ctx, size in
                    var t = ctx.resolve(base)
                    let m = t.measure(in: CGSize(width: 4000, height: 4000))
                    let center = CGPoint(x: size.width / 2, y: size.height / 2 - stroke * 0.6)
                    let avail = size.width - stroke * 3
                    if m.width > avail, m.width > 0 {   // the layout shrank it (minimumScaleFactor): follow
                        let k = avail / m.width
                        ctx.translateBy(x: center.x, y: center.y); ctx.scaleBy(x: k, y: k); ctx.translateBy(x: -center.x, y: -center.y)
                    }
                    let drop = stroke * 1.2
                    t.shading = .color(Theme.ink)
                    for pass in 0..<2 {
                        let dy = pass == 0 ? drop : 0        // the shadow first, then the outline
                        for i in 0..<8 {
                            let a = Double(i) / 8 * 2 * .pi
                            ctx.draw(t, at: CGPoint(x: center.x + cos(a) * stroke, y: center.y + sin(a) * stroke + dy), anchor: .center)
                        }
                        if pass == 0 { ctx.draw(t, at: CGPoint(x: center.x, y: center.y + dy), anchor: .center) }
                    }
                    t.shading = .color(color)
                    ctx.draw(t, at: center, anchor: .center)
                }
            }
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

/// Paper grain over any fill: faint specks and fibres, rasterized once per
/// size (a Canvas here was redrawn on every parent update — thousands of
/// ellipses each time the Studio's state changed).
struct PaperGrain: View {
    var opacity: Double = 0.10
    var body: some View {
        GeometryReader { g in
            Image(uiImage: GrainCache.image(for: g.size))
                .resizable()
                .frame(width: g.size.width, height: g.size.height)
        }
        .opacity(opacity)
        .allowsHitTesting(false)
    }
}

enum GrainCache {
    nonisolated(unsafe) private static var cache: [String: UIImage] = [:]

    static func image(for size: CGSize) -> UIImage {
        // bucket sizes to 16 pt so a resizing pane doesn't mint a new image per pixel
        let w = max(16, (Int(size.width) / 16 + 1) * 16), h = max(16, (Int(size.height) / 16 + 1) * 16)
        let key = "\(w)x\(h)"
        if let img = cache[key] { return img }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let img = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            var rng = SeededRandom(seed: 7)
            let n = w * h / 90
            let c = ctx.cgContext
            for _ in 0..<n {
                let x = rng.unit() * Double(w), y = rng.unit() * Double(h)
                let r = 0.4 + rng.unit() * 0.9
                c.setFillColor(rng.unit() < 0.55 ? UIColor.black.withAlphaComponent(0.5).cgColor : UIColor.white.withAlphaComponent(0.8).cgColor)
                c.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
            }
            c.setStrokeColor(UIColor.white.withAlphaComponent(0.6).cgColor)
            c.setLineWidth(0.6)
            for _ in 0..<(n / 40) {
                let x = rng.unit() * Double(w), y = rng.unit() * Double(h)
                c.move(to: CGPoint(x: x, y: y))
                c.addLine(to: CGPoint(x: x + (rng.unit() - 0.5) * 14, y: y + (rng.unit() - 0.5) * 3))
                c.strokePath()
            }
        }
        if cache.count > 24 { cache.removeAll() }
        cache[key] = img
        return img
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
