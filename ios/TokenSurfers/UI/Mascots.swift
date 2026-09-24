import SwiftUI

/// The splat: a Claude-orange asterisk of rounded arms, as cut from paper.
struct SplatShape: Shape {
    var arms = 11
    var wobble: Double = 0      // animates arm lengths
    var seed: UInt64 = 3

    var animatableData: Double {
        get { wobble }
        set { wobble = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        var rng = SeededRandom(seed: seed)
        let w = R * 0.25
        for i in 0..<arms {
            let base = Double(i) / Double(arms) * 2 * .pi + (rng.unit() - 0.5) * 0.18
            let len = R * (0.82 + rng.unit() * 0.18 + sin(wobble * 2 + Double(i) * 1.7) * 0.05)
            let arm = Path(roundedRect: CGRect(x: 0, y: -w / 2, width: len, height: w), cornerRadius: w / 2)
            p.addPath(arm, transform: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: base))
        }
        p.addEllipse(in: CGRect(x: c.x - R * 0.36, y: c.y - R * 0.36, width: R * 0.72, height: R * 0.72))
        return p
    }
}

/// The splat with its kawaii face, white paper edge and hard shadow.
struct SplatMascot: View {
    var size: CGFloat = 120
    var face = true
    var mood: Mood = .happy
    var animate = true

    enum Mood { case happy, wow, dead }

    var body: some View {
        TimelineView(.animation(paused: !animate)) { tl in
            let t = animate ? tl.date.timeIntervalSinceReferenceDate : 0
            ZStack {
                SplatShape(wobble: t)
                    .stroke(.white, style: StrokeStyle(lineWidth: size * 0.05, lineJoin: .round))
                SplatShape(wobble: t)
                    .fill(Theme.splat)
                SplatShape(wobble: t)
                    .fill(Theme.splatDark.opacity(0.25))
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                PaperGrain(opacity: 0.12).mask(SplatShape(wobble: t))
                if face { SplatFace(size: size, mood: mood, blink: blink(t)) }
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: size * 0.03)
            .rotationEffect(.degrees(animate ? sin(t * 1.3) * 4 : 0))
        }
    }

    private func blink(_ t: Double) -> Bool { t.truncatingRemainder(dividingBy: 3.7) < 0.12 }
}

struct SplatFace: View {
    let size: CGFloat
    var mood: SplatMascot.Mood = .happy
    var blink = false

    var body: some View {
        let e = size * 0.085
        ZStack {
            HStack(spacing: size * 0.13) {
                eye(e)
                eye(e)
            }
            .offset(y: -size * 0.02)
            // cheeks
            HStack(spacing: size * 0.3) {
                Ellipse().fill(Theme.pink.opacity(0.8)).frame(width: e * 1.2, height: e * 0.6)
                Ellipse().fill(Theme.pink.opacity(0.8)).frame(width: e * 1.2, height: e * 0.6)
            }
            .offset(y: size * 0.05)
            mouth
                .offset(y: size * 0.075)
        }
    }

    @ViewBuilder private func eye(_ e: CGFloat) -> some View {
        if mood == .dead {
            Text("✕").font(.system(size: e * 1.5, weight: .black)).foregroundStyle(Theme.ink)
        } else if blink {
            Capsule().fill(Theme.ink).frame(width: e, height: e * 0.22)
        } else {
            ZStack {
                Circle().fill(.white).frame(width: e * 1.25, height: e * 1.25)
                Circle().fill(Theme.ink).frame(width: e, height: e)
                Circle().fill(.white).frame(width: e * 0.34, height: e * 0.34).offset(x: e * 0.18, y: -e * 0.2)
            }
        }
    }

    @ViewBuilder private var mouth: some View {
        switch mood {
        case .happy:
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addQuadCurve(to: CGPoint(x: size * 0.08, y: 0), control: CGPoint(x: size * 0.04, y: size * 0.05))
            }
            .fill(Theme.ink)
            .frame(width: size * 0.08, height: size * 0.04)
        case .wow:
            Ellipse().fill(Theme.ink).frame(width: size * 0.06, height: size * 0.075)
        case .dead:
            Capsule().fill(Theme.ink).frame(width: size * 0.07, height: size * 0.015)
        }
    }
}

/// Tok Tok Tok Tokenur: a wooden token with a coin on its belly.
struct Tokenur: View {
    var size: CGFloat = 200
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let w = size * 0.5, h = size * 0.95
            ZStack {
                // arms
                Capsule().fill(Color(hex: 0x5A3A22)).frame(width: size * 0.3, height: size * 0.035)
                    .rotationEffect(.degrees(-50 + sin(t * 8) * 25), anchor: .trailing)
                    .offset(x: -w * 0.62, y: -h * 0.02)
                Capsule().fill(Color(hex: 0x5A3A22)).frame(width: size * 0.25, height: size * 0.035)
                    .rotationEffect(.degrees(20 - sin(t * 8) * 20), anchor: .leading)
                    .offset(x: w * 0.6, y: -h * 0.12)
                // legs
                HStack(spacing: w * 0.35) {
                    Capsule().fill(Color(hex: 0x4A2E1A)).frame(width: size * 0.03, height: size * 0.16)
                    Capsule().fill(Color(hex: 0x4A2E1A)).frame(width: size * 0.03, height: size * 0.16)
                }
                .offset(y: h * 0.55)
                // body
                RoundedRectangle(cornerRadius: w * 0.5, style: .continuous)
                    .fill(Color(hex: 0xB98A5A))
                    .overlay(woodGrain(w: w, h: h))
                    .overlay(RoundedRectangle(cornerRadius: w * 0.5, style: .continuous).strokeBorder(.white, lineWidth: 2))
                    .frame(width: w, height: h)
                // ear
                Circle().fill(Color(hex: 0x8A5E38)).frame(width: w * 0.3).offset(x: -w * 0.5, y: -h * 0.24)
                // face
                VStack(spacing: size * 0.02) {
                    HStack(spacing: w * 0.16) {
                        googly(size * 0.1, look: sin(t * 3))
                        googly(size * 0.1, look: sin(t * 3))
                    }
                    Path { p in
                        p.move(to: .zero)
                        p.addQuadCurve(to: CGPoint(x: size * 0.16, y: 0), control: CGPoint(x: size * 0.08, y: size * 0.08))
                    }
                    .fill(Color(hex: 0x3A2012))
                    .frame(width: size * 0.16, height: size * 0.05)
                }
                .offset(y: -h * 0.2)
                // coin
                ZStack {
                    Circle().fill(Theme.yellow).overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    Rectangle().fill(Theme.splat).frame(width: size * 0.07, height: size * 0.07).rotationEffect(.degrees(45))
                }
                .frame(width: size * 0.2)
                .offset(y: h * 0.17)
            }
            .offset(y: sin(t * 8) * size * 0.015)
        }
        .frame(width: size, height: size * 1.1)
    }

    private func googly(_ d: CGFloat, look: Double) -> some View {
        ZStack {
            Circle().fill(.white)
            Circle().fill(Theme.ink).frame(width: d * 0.5).offset(x: d * 0.15 * look)
        }
        .frame(width: d, height: d)
    }

    private func woodGrain(w: CGFloat, h: CGFloat) -> some View {
        Canvas { ctx, size in
            for i in 0..<8 {
                let y = size.height * (0.1 + Double(i) * 0.11)
                var p = Path()
                p.move(to: CGPoint(x: size.width * 0.15, y: y))
                p.addQuadCurve(to: CGPoint(x: size.width * 0.85, y: y + 3), control: CGPoint(x: size.width * 0.5, y: y - 5))
                ctx.stroke(p, with: .color(Color(hex: 0x7A5230).opacity(0.5)), lineWidth: 1.2)
            }
        }
    }
}

/// Contextino Windowini: a browser window with a shark fin, tail and teeth.
struct Contextino: View {
    var size: CGFloat = 220
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let w = size, h = size * 0.62
            ZStack {
                // fin + tail
                Triangle().fill(Color(hex: 0x8E9BB5)).frame(width: w * 0.28, height: h * 0.45)
                    .offset(x: w * 0.12, y: -h * 0.66)
                Triangle().fill(Color(hex: 0x8E9BB5)).frame(width: w * 0.3, height: h * 0.55)
                    .rotationEffect(.degrees(-90 + sin(t * 5) * 8))
                    .offset(x: -w * 0.6, y: 0)
                // legs
                HStack(spacing: w * 0.3) {
                    leg; leg
                }
                .offset(y: h * 0.62)
                // window
                VStack(spacing: 0) {
                    HStack(spacing: w * 0.02) {
                        ForEach([Color(hex: 0xF05B4F), Color(hex: 0xF6C343), Color(hex: 0x4FC35F)], id: \.self) { c in
                            Circle().fill(c).frame(width: w * 0.045)
                        }
                        ForEach(0..<5, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0xA79CD6)).frame(height: h * 0.1)
                        }
                    }
                    .padding(.horizontal, w * 0.04)
                    .frame(height: h * 0.2)
                    .background(Color(hex: 0xCBC3F0))
                    ZStack {
                        Color(hex: 0xF6EFE2)
                        VStack(spacing: h * 0.08) {
                            HStack(spacing: w * 0.28) {
                                eye(h * 0.16); eye(h * 0.16)
                            }
                            teeth(w: w * 0.62, h: h * 0.24, open: 0.6 + sin(t * 6) * 0.4)
                        }
                    }
                }
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white, lineWidth: 3))
            }
            .offset(y: sin(t * 2) * 4)
        }
        .frame(width: size * 1.3, height: size * 1.1)
    }

    private var leg: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(hex: 0x9AA3B8)).frame(width: size * 0.03, height: size * 0.12)
            Capsule().fill(Color(hex: 0x3767C8)).frame(width: size * 0.12, height: size * 0.05)
        }
    }

    private func eye(_ d: CGFloat) -> some View {
        ZStack {
            Circle().fill(.white).overlay(Circle().strokeBorder(Theme.ink.opacity(0.1)))
            Circle().fill(Theme.ink).frame(width: d * 0.45)
        }
        .frame(width: d, height: d)
    }

    private func teeth(w: CGFloat, h: CGFloat, open: Double) -> some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Color(hex: 0x3A1E24))
            HStack(spacing: 0) {
                ForEach(0..<9, id: \.self) { _ in
                    Triangle().rotation(.degrees(180)).fill(.white)
                }
            }
            .frame(height: h * 0.4)
        }
        .frame(width: w, height: h * (0.5 + open * 0.5))
    }
}

/// Hallucinello Confidenzo: a pink brain cloud in sunglasses, 100% sure.
struct Hallucinello: View {
    var size: CGFloat = 220
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<9, id: \.self) { i in
                    let a = Double(i) / 9 * 2 * .pi
                    Circle().fill(Color(hex: 0xF4A7C4))
                        .frame(width: size * 0.42)
                        .offset(x: cos(a) * size * 0.26, y: sin(a) * size * 0.18)
                }
                Ellipse().fill(Color(hex: 0xF4A7C4)).frame(width: size * 0.7, height: size * 0.5)
                // brain folds
                ForEach(0..<6, id: \.self) { i in
                    Capsule().stroke(Color(hex: 0xD97FA3), lineWidth: 2)
                        .frame(width: size * 0.16, height: size * 0.05)
                        .rotationEffect(.degrees(Double(i) * 30))
                        .offset(x: CGFloat(i % 3 - 1) * size * 0.2, y: CGFloat(i / 3) * size * 0.16 - size * 0.18)
                }
                // sunglasses
                HStack(spacing: size * 0.02) {
                    RoundedRectangle(cornerRadius: size * 0.04).fill(Theme.ink).frame(width: size * 0.2, height: size * 0.1)
                    Rectangle().fill(Theme.ink).frame(width: size * 0.06, height: size * 0.02)
                    RoundedRectangle(cornerRadius: size * 0.04).fill(Theme.ink).frame(width: size * 0.2, height: size * 0.1)
                }
                .offset(y: size * 0.02)
                Path { p in
                    p.move(to: .zero)
                    p.addQuadCurve(to: CGPoint(x: size * 0.14, y: -size * 0.02), control: CGPoint(x: size * 0.08, y: size * 0.04))
                }
                .stroke(Theme.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: size * 0.14, height: size * 0.04)
                .offset(x: size * 0.03, y: size * 0.15)
                Text("100%").font(Theme.black(size * 0.06)).foregroundStyle(Theme.ink.opacity(0.6))
                    .offset(y: size * 0.36)
            }
            .rotationEffect(.degrees(sin(t * 2.2) * 5))
            .scaleEffect(1 + sin(t * 4) * 0.02)
        }
        .frame(width: size * 1.1, height: size * 0.9)
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
