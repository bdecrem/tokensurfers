import SwiftUI

/// The in-game Splat: the starburst blob from the original mockup (misc/3.MP4)
/// — an orange splat with ten rounded arms of uneven length that spins all
/// the time, whose arms breathe and lag with spring physics. Bart picked it
/// over the tube man for the track (2026-09-24): small and always moving, a
/// spinning splat reads as alive; the tube man (SurferArt) stays the Splat of
/// Home and the composer, where there is a face to see.
///
/// The springs live in `BlobState` (one per engine) because the renderer is a
/// struct built every frame; everything else is a function of the pose.
final class BlobState {
    var len: [Double] = []
    var vel: [Double] = []
    var theta = 0.0
    var rate = 0.0
    var lastT = -1.0
    var wasAirborne = false
}

enum BlobArt {
    static let arms = 14
    /// Tip radius at rest, body radius, arm width, sticker edge (world units).
    static let R = 0.43
    static let body = 0.18
    static let width = 0.16
    static let edge = 0.05
    /// The blob floats: its centre sits this high above the ground it runs on.
    static let hover = 0.5

    static let fill = Color(hex: 0xF08A55)
    static let discOuter = Color(hex: 0xFFE9CC)
    static let discInner = Color(hex: 0xF8B27C)
    static let ink = Color(hex: 0x1D1530)

    /// Fixed per-arm character: base length and breathing phase.
    private static let seeds: [(len: Double, phase: Double, w: Double, thick: Double)] = (0..<arms).map { i in
        var rng = SeededRandom(seed: 91 + UInt64(i) * 7)
        return (0.55 + 0.6 * rng.unit(), rng.unit() * 2 * .pi, 2.4 + rng.unit() * 2.2, 0.7 + rng.unit() * 0.65)
    }

    /// `origin` is the ground point under the character on screen; `unit` is pixels per world unit.
    static func draw(_ ctx: inout GraphicsContext, origin: CGPoint, unit: CGFloat, pose p: SurferPose, state s: BlobState) {
        step(s, p)
        var c = ctx
        c.translateBy(x: origin.x, y: origin.y)

        // the shadow on the track, smaller the higher it goes
        let sh = max(0.35, 1 - p.lift * 0.22)
        c.fill(Path(ellipseIn: CGRect(x: -R * 0.9 * unit * sh, y: -0.11 * unit * sh, width: R * 1.8 * unit * sh, height: 0.22 * unit * sh)),
               with: .color(ink.opacity(0.24)))

        let dead = p.dead >= 0
        let drop = dead ? min(1, p.dead * 2.5) : 0          // crashed: it sinks to the ground
        let bob = dead ? 0 : 0.045 * sin(p.t * 7.3) + 0.012 * sin(p.t * 23.7)   // never quite still
        let centreY = -(hover + p.lift + bob) * unit + drop * (hover - body) * unit
        c.translateBy(x: 0, y: centreY)
        c.scaleBy(x: unit, y: unit)

        // squash on landing, flatten in a roll, lean in a stumble
        if p.rolling > 0 {
            let wob = sin(p.t * 26) * 0.04
            c.translateBy(x: 0, y: hover - body)
            c.scaleBy(x: 1.22 + wob, y: 0.55 - wob)
            c.translateBy(x: 0, y: -(hover - body))
        } else if !dead {
            let squash = p.sinceLanded < 0.14 ? 1 - (0.14 - p.sinceLanded) * 1.3 : 1.0
            let sy = squash * (p.lift > 0.03 ? 1.05 : 1.0)
            c.rotate(by: .radians(p.lean * 0.8))
            c.scaleBy(x: 1 / sy, y: sy)
        }
        c.rotate(by: .radians(s.theta))

        // one silhouette: the arms and the body as round-capped strokes, white edge first
        let bodyRect = CGRect(x: -body, y: -body, width: body * 2, height: body * 2)
        let tone = dead ? Color(hex: 0xC98B6A) : fill
        for pass in 0..<2 {
            let color: Color = pass == 0 ? .white : tone
            let extra = pass == 0 ? edge * 2 : 0
            for i in 0..<arms {
                let a = Double(i) / Double(arms) * 2 * .pi
                var arm = Path()
                arm.move(to: .zero)
                arm.addLine(to: CGPoint(x: cos(a) * s.len[i], y: sin(a) * s.len[i]))
                c.stroke(arm, with: .color(color), style: StrokeStyle(lineWidth: width * seeds[i].thick + extra, lineCap: .round))
            }
            c.fill(Path(ellipseIn: bodyRect.insetBy(dx: -extra / 2, dy: -extra / 2)), with: .color(color))
        }

        // the token in the middle (it doesn't spin with the arms)
        c.rotate(by: .radians(-s.theta))
        let ro = 0.16, ri = 0.085
        c.fill(Path(ellipseIn: CGRect(x: -ro, y: -ro, width: ro * 2, height: ro * 2)), with: .color(discOuter))
        c.fill(Path(ellipseIn: CGRect(x: -ri, y: -ri + 0.02, width: ri * 2, height: ri * 2)), with: .color(discInner))
        if dead {
            // X eyes on the token
            var x = Path()
            for dx in [-0.075, 0.075] {
                x.move(to: CGPoint(x: dx - 0.035, y: -0.04)); x.addLine(to: CGPoint(x: dx + 0.035, y: 0.03))
                x.move(to: CGPoint(x: dx + 0.035, y: -0.04)); x.addLine(to: CGPoint(x: dx - 0.035, y: 0.03))
            }
            c.stroke(x, with: .color(ink), style: StrokeStyle(lineWidth: 0.025, lineCap: .round))
        }
    }

    /// The springs: every arm chases a breathing target with a little lag and
    /// overshoot; lane changes, the air, landings and the crash push on them.
    private static func step(_ s: BlobState, _ p: SurferPose) {
        if s.len.count != arms {
            s.len = seeds.map { $0.len * R }
            s.vel = Array(repeating: 0, count: arms)
            s.theta = 0
            s.rate = 1.3
            s.lastT = p.t
        }
        let dt = min(0.05, max(0, p.t - s.lastT))
        s.lastT = p.t
        guard dt > 0 else { return }

        let dead = p.dead >= 0
        let air = p.lift > 0.03
        // spin: steady, faster with speed, a boost in the air and in a roll, none when dead
        var target = dead ? 0 : 2.1 + 1.3 * p.speed
        if air { target += 4 }
        if p.rolling > 0 { target += 7 }
        s.rate += (target - s.rate) * min(1, 6 * dt)
        s.theta += s.rate * dt

        let landed = s.wasAirborne && !air
        s.wasAirborne = air
        let k = 62.0, damp = 8.5
        for i in 0..<arms {
            let seed = seeds[i]
            // the arm's direction on screen, after the spin
            let a = Double(i) / Double(arms) * 2 * .pi + s.theta
            var goal = seed.len * R * (1 + 0.11 * sin(seed.w * p.t + seed.phase) + 0.05 * sin(seed.w * 1.9 * p.t + seed.phase * 2)
                                       + 0.03 * sin(seed.w * 4.7 * p.t + seed.phase * 3))   // the jitter
            // trailing arms stretch behind a lane change
            goal += 0.30 * R * max(0, -cos(a) * p.sway)
            // hanging arms dangle in the air
            if air { goal += 0.22 * R * max(0, sin(a)) * min(1, p.lift / 0.5) }
            if dead { goal = seed.len * R * 0.5 }
            if landed { s.vel[i] += 2.2 }
            s.vel[i] += (-k * (s.len[i] - goal) - damp * s.vel[i]) * dt
            s.len[i] += s.vel[i] * dt
            s.len[i] = max(body * 0.6, s.len[i])
        }
    }
}

/// The blob as a view: Home, the composer's status pill, the cards, the
/// cutaways, the game-over card. The same drawing, spinning and breathing in
/// place. `energy` is how lively it is (the status pill idles low while Splat
/// thinks); `.dead` shows the wilted one with X eyes.
struct BlobHero: View {
    var unit: CGFloat = 80
    var mood: SurferPose.Mood = .happy
    var running = true
    var front = true
    var energy: Double = 1
    @State private var state = BlobState()

    var body: some View {
        TimelineView(.animation(paused: !running)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                var p = SurferPose()
                p.t = running ? t : 0.4
                p.speed = running ? energy : 0
                p.dead = mood == .dead ? 1 : -1
                // px per world unit, so the blob's height is about the tube man's was
                BlobArt.draw(&ctx, origin: CGPoint(x: size.width / 2, y: size.height - unit * 0.12), unit: unit * 1.55, pose: p, state: state)
            }
        }
        .frame(width: unit * 1.7, height: unit * 1.7)
    }
}
