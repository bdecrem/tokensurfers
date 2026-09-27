import SwiftUI

/// The in-game Splat: the starburst blob from the original mockup (misc/3.MP4)
/// — an orange splat with twelve rounded arms of uneven length that spins all
/// the time, whose arms breathe and lag with spring physics. Bart picked it
/// over the tube man for the track (2026-09-24): small and always moving, a
/// spinning splat reads as alive; the tube man (SurferArt) stays the Splat of
/// Home and the composer, where there is a face to see.
///
/// 2026-09-25: ~8% smaller, spins a quarter faster, fidgets twice as often
/// (each kick jolts the whole body), and reads as a solid thing: the arms are
/// lit from the upper left in screen space so the shading sweeps across them
/// as it spins, the arms pointing at the camera are drawn last and a touch
/// thicker, a soft dark ring sits where they root into the core, and the core
/// has a radial highlight and a specular dot.
///
/// The springs live in `BlobState` (one per engine) because the renderer is a
/// struct built every frame; everything else is a function of the pose.
///
/// The Home character (`HomeSplat`) drives the same drawing through the
/// override fields on `BlobState` — dozing, stretching, spin kicks, a bigger
/// core with a face instead of the seed dots, tints and a flash. The track
/// never sets them, so their defaults are the track's behaviour.
final class BlobState {
    var len: [Double] = []
    var vel: [Double] = []
    var theta = 0.0
    var rate = 0.0
    var lastT = -1.0
    var wasAirborne = false
    var twitchIn = 0.3
    var jolt = 0.0             // the body's flinch after an arm kick, decays
    var rng = SeededRandom(seed: 4242)

    // Overrides for the Home character (HomeSplat's brain writes these every frame).
    var doze = 0.0             // 0 awake … 1 asleep: the spin stops, the arms give in to gravity, the breathing slows
    var puff = 0.0             // every arm stretches by this fraction (a yawn, the big morning stretch)
    var spinScale = 1.0        // multiplies the spin target (winding down, held still)
    var spinKick = 0.0         // an impulse on the spin rate, either direction; decays here
    var fidget = 1.0           // how often an arm twitches, × the track's rate (0 = never)
    var bodyScale = 1.0        // a bigger core: room for a face
    var squash = CGSize(width: 1, height: 1)   // extra scale from the brain (crouch, stretch, sit)
    var sink = 0.0             // the centre sits this much lower (world units)
    var tint: (r: Double, g: Double, b: Double) = (0, 0, 0)
    var tintK = 0.0            // how far the skin leans toward `tint`
    var flash = 0.0            // 0…1, whitens the skin (a startle); decays here
    var hideToken = false      // the face replaces the seed dots
}

enum BlobArt {
    static let arms = 12
    /// Tip radius at rest, body radius, arm width, sticker edge (world units).
    /// Measured off the reference video (2026-09-24): arms about a quarter of
    /// the tip radius wide, a core about a quarter of it, a hairline edge —
    /// more tentacle, less body. A fat edge is what fused the first version
    /// into a cloud. Sized down 8% on 2026-09-25.
    static let R = 0.48
    static let body = 0.106
    static let width = 0.106
    static let edge = 0.014
    /// The blob floats: its centre sits this high above the ground it runs on.
    static let hover = 0.47

    static let fill = Color(hex: 0xE68A5C)        // the reference's matte terracotta
    static let seed = Color(hex: 0xF7D66B)        // the pale-yellow dot at its heart
    static let ink = Color(hex: 0x1D1530)
    /// Light from the upper left of the screen; the arms take it as they turn through it.
    static let lightAngle = -2.3                  // radians, screen space (y down)
    private static let fillRGB = (r: 0.902, g: 0.541, b: 0.361)
    private static let litRGB = (r: 1.0, g: 0.72, b: 0.55)
    private static let shadeRGB = (r: 0.72, g: 0.37, b: 0.22)
    private static let coreHiRGB = (r: 1.0, g: 0.698, b: 0.498)     // FFB27F
    private static let coreLoRGB = (r: 0.722, g: 0.353, b: 0.192)   // B85A31

    /// Fixed per-arm character: base length and breathing phase.
    private static let seeds: [(len: Double, phase: Double, w: Double, thick: Double)] = (0..<arms).map { i in
        var rng = SeededRandom(seed: 91 + UInt64(i) * 7)
        return (0.6 + 0.4 * rng.unit(), rng.unit() * 2 * .pi, 2.0 + rng.unit() * 1.8, 0.8 + rng.unit() * 0.4)
    }

    /// A colour after the brain's tint and flash.
    private static func mood(_ c: (r: Double, g: Double, b: Double), _ s: BlobState) -> Color {
        var r = c.r, g = c.g, b = c.b
        if s.tintK > 0 { r += (s.tint.r - r) * s.tintK; g += (s.tint.g - g) * s.tintK; b += (s.tint.b - b) * s.tintK }
        if s.flash > 0 { let k = s.flash * 0.85; r += (1 - r) * k; g += (1 - g) * k; b += (1 - b) * k }
        return Color(red: r, green: g, blue: b)
    }

    /// The skin colour right now (the Home face paints its eyelids with it).
    static func skin(_ s: BlobState) -> Color { mood(fillRGB, s) }

    private static func blend(_ lit: Double, dead: Bool, _ s: BlobState) -> Color {
        if dead { return Color(hex: 0xC98B6A) }
        let base = fillRGB
        let to = lit >= 0 ? litRGB : shadeRGB
        let k = min(1, abs(lit)) * (lit >= 0 ? 0.42 : 0.38)
        return mood((r: base.r + (to.r - base.r) * k, g: base.g + (to.g - base.g) * k, b: base.b + (to.b - base.b) * k), s)
    }

    /// `origin` is the ground point under the character on screen; `unit` is pixels per world unit.
    /// `face` draws on top of the core in world units, centred and unrotated (the Home character's face).
    /// Returns the centre of the body in the caller's pixels (before squash and lean), for anything drawn around it.
    @discardableResult
    static func draw(_ ctx: inout GraphicsContext, origin: CGPoint, unit: CGFloat, pose p: SurferPose, state s: BlobState,
                     face: ((inout GraphicsContext) -> Void)? = nil) -> CGPoint {
        step(s, p)
        var c = ctx
        c.translateBy(x: origin.x, y: origin.y)

        // the shadow on the track, smaller the higher it goes
        let sh = max(0.35, 1 - p.lift * 0.22)
        c.fill(Path(ellipseIn: CGRect(x: -R * 0.9 * unit * sh, y: -0.11 * unit * sh, width: R * 1.8 * unit * sh, height: 0.22 * unit * sh)),
               with: .color(ink.opacity(0.24)))

        let dead = p.dead >= 0
        let drop = dead ? min(1, p.dead * 2.5) : 0          // crashed: it sinks to the ground
        // never quite still, never much: a quick bob, a faster flutter, a sideways jitter — asleep, one slow breath instead
        let calm: Double = 1 - 0.85 * s.doze
        let quick: Double = 0.022 * sin(p.t * 7.1) + 0.010 * sin(p.t * 27.0)
        let breath: Double = s.doze * 0.014 * sin(p.t * 2.0)
        let bob: Double = dead ? 0 : quick * calm + breath
        let jitterX: Double = dead ? 0 : 0.012 * sin(p.t * 19.0) * sin(p.t * 3.3) * calm
        let centreY = -(hover + p.lift + bob - s.sink) * unit + drop * (hover - body) * unit
        c.translateBy(x: jitterX * unit, y: centreY)
        c.scaleBy(x: unit, y: unit)
        let centre = CGPoint(x: origin.x + jitterX * unit, y: origin.y + centreY)

        // squash on landing, flatten in a roll, lean in a stumble, a jolt after a kick
        if p.rolling > 0 {
            let wob = sin(p.t * 26) * 0.04
            c.translateBy(x: 0, y: hover - body)
            c.scaleBy(x: 1.22 + wob, y: 0.55 - wob)
            c.translateBy(x: 0, y: -(hover - body))
        } else if !dead {
            let squash = p.sinceLanded < 0.14 ? 1 - (0.14 - p.sinceLanded) * 1.3 : 1.0
            let sy = squash * (p.lift > 0.03 ? 1.05 : 1.0)
            let jolt = 1 + 0.035 * s.jolt
            c.rotate(by: .radians(p.lean * 0.8))
            c.scaleBy(x: jolt / sy * s.squash.width, y: sy * jolt * s.squash.height)
        }

        // Each arm's direction on screen decides its shade (fixed light) and its
        // depth: the ones pointing at the camera (down the screen) go last, a
        // touch thicker and longer; the ones pointing away go first, thinner.
        var order = Array(0..<arms)
        var screenAngle = [Double](repeating: 0, count: arms)
        for i in 0..<arms { screenAngle[i] = Double(i) / Double(arms) * 2 * .pi + s.theta }
        order.sort { sin(screenAngle[$0]) < sin(screenAngle[$1]) }

        c.rotate(by: .radians(s.theta))
        let bodyR = body * s.bodyScale
        let bodyRect = CGRect(x: -bodyR, y: -bodyR, width: bodyR * 2, height: bodyR * 2)
        // the white hairline silhouette
        for i in 0..<arms {
            let a = Double(i) / Double(arms) * 2 * .pi
            let depth = sin(screenAngle[i])
            let len = s.len[i] * (1 + 0.05 * depth)
            var arm = Path()
            arm.move(to: .zero)
            arm.addLine(to: CGPoint(x: cos(a) * len, y: sin(a) * len))
            c.stroke(arm, with: .color(.white), style: StrokeStyle(lineWidth: width * seeds[i].thick * (1 + 0.08 * depth) + edge * 2, lineCap: .round))
        }
        c.fill(Path(ellipseIn: bodyRect.insetBy(dx: -edge, dy: -edge)), with: .color(.white))
        // the arms, far to near, each in its own light
        for i in order {
            let a = Double(i) / Double(arms) * 2 * .pi
            let depth = sin(screenAngle[i])
            let lit = cos(screenAngle[i] - lightAngle)
            let len = s.len[i] * (1 + 0.05 * depth)
            let w = width * seeds[i].thick * (1 + 0.08 * depth)
            var arm = Path()
            arm.move(to: .zero)
            arm.addLine(to: CGPoint(x: cos(a) * len, y: sin(a) * len))
            c.stroke(arm, with: .color(blend(lit, dead: dead, s)), style: StrokeStyle(lineWidth: w, lineCap: .round))
            // a thin highlight down the lit side of the near, lit arms: a rounded tube, not a stripe
            if !dead, lit > 0.25, depth > -0.3 {
                var hi = Path()
                let off = 0.28 * w
                let ox = cos(lightAngle - s.theta) * off, oy = sin(lightAngle - s.theta) * off
                hi.move(to: CGPoint(x: ox + cos(a) * len * 0.18, y: oy + sin(a) * len * 0.18))
                hi.addLine(to: CGPoint(x: ox + cos(a) * len * 0.92, y: oy + sin(a) * len * 0.92))
                c.stroke(hi, with: .color(.white.opacity(0.18 * lit)), style: StrokeStyle(lineWidth: w * 0.3, lineCap: .round))
            }
        }
        // where the arms root into the core: a soft dark ring, then the core itself, lit from the upper left
        c.fill(Path(ellipseIn: bodyRect.insetBy(dx: -bodyR * 0.55, dy: -bodyR * 0.55)), with: .color(ink.opacity(dead ? 0.06 : 0.11)))
        c.rotate(by: .radians(-s.theta))
        if dead {
            c.fill(Path(ellipseIn: bodyRect), with: .color(Color(hex: 0xC98B6A)))
        } else {
            let hl = CGPoint(x: cos(lightAngle) * bodyR * 0.45, y: sin(lightAngle) * bodyR * 0.45)
            c.fill(Path(ellipseIn: bodyRect), with: .radialGradient(
                Gradient(stops: [.init(color: mood(coreHiRGB, s), location: 0), .init(color: mood(fillRGB, s), location: 0.55), .init(color: mood(coreLoRGB, s), location: 1)]),
                center: hl, startRadius: 0, endRadius: bodyR * 1.5))
            c.fill(Path(ellipseIn: CGRect(x: hl.x - 0.014, y: hl.y - 0.014, width: 0.028, height: 0.028)), with: .color(.white.opacity(0.55)))
        }

        // the token in the middle (it doesn't spin with the arms)
        if !s.hideToken {
            let ro = 0.042, ri = 0.019
            c.fill(Path(ellipseIn: CGRect(x: -ro + 0.01, y: -ro + 0.02, width: ro * 2, height: ro * 2)), with: .color(seed))
            c.fill(Path(ellipseIn: CGRect(x: 0.02 - ri, y: -0.08 - ri, width: ri * 2, height: ri * 2)), with: .color(seed))
        }
        if dead {
            // X eyes on the token
            var x = Path()
            for dx in [-0.05, 0.05] {
                x.move(to: CGPoint(x: dx - 0.025, y: -0.03)); x.addLine(to: CGPoint(x: dx + 0.025, y: 0.02))
                x.move(to: CGPoint(x: dx + 0.025, y: -0.03)); x.addLine(to: CGPoint(x: dx - 0.025, y: 0.02))
            }
            c.stroke(x, with: .color(ink), style: StrokeStyle(lineWidth: 0.02, lineCap: .round))
        }
        face?(&c)
        return centre
    }

    /// The springs: every arm chases a breathing target with a little lag and
    /// overshoot; lane changes, the air, landings and the crash push on them.
    private static func step(_ s: BlobState, _ p: SurferPose) {
        if s.len.count != arms {
            s.len = seeds.map { $0.len * R }
            s.vel = Array(repeating: 0, count: arms)
            s.theta = 0
            s.rate = 1.6
            s.lastT = p.t
        }
        let dt = min(0.05, max(0, p.t - s.lastT))
        s.lastT = p.t
        guard dt > 0 else { return }

        let dead = p.dead >= 0
        let air = p.lift > 0.03
        // spin: steady, faster with speed, a boost in the air and in a roll, none when dead or asleep
        // nervous: the spin wanders ±35% around its target instead of holding it
        let nervous = 1 + 0.35 * sin(p.t * 4.6) * sin(p.t * 1.7 + 0.8)
        var target = dead ? 0 : (2.25 + 1.5 * p.speed) * nervous * s.spinScale * (1 - s.doze)
        if air { target += 4.8 * s.spinScale * (1 - s.doze) }
        if p.rolling > 0 { target += 8 }
        target += s.spinKick
        s.spinKick -= s.spinKick * min(1, 2.4 * dt)
        s.flash = max(0, s.flash - dt * 3.5)
        s.rate += (target - s.rate) * min(1, 8 * dt)
        s.theta += s.rate * dt
        s.jolt = max(0, s.jolt - dt * 7)
        // a twitch: every so often one arm gets a kick, in or out, and the body flinches
        s.twitchIn -= dt * s.fidget
        if s.twitchIn <= 0 && !dead {
            s.twitchIn = 0.1 + s.rng.unit() * 0.24
            let i = s.rng.int(arms)
            s.vel[i] += (s.rng.unit() < 0.5 ? -1 : 1) * (1.8 + s.rng.unit() * 2.4)
            if s.rng.unit() < 0.3 { s.vel[(i + arms / 2) % arms] += 1.5 }   // sometimes the opposite arm answers
            s.jolt = 1
        }

        let landed = s.wasAirborne && !air
        s.wasAirborne = air
        let k = 70.0, damp = 7.0
        let calm = 1 - 0.7 * s.doze
        for i in 0..<arms {
            let seed = seeds[i]
            // the arm's direction on screen, after the spin
            let a = Double(i) / Double(arms) * 2 * .pi + s.theta
            let jitter: Double = 0.14 * sin(seed.w * p.t + seed.phase) + 0.06 * sin(seed.w * 1.9 * p.t + seed.phase * 2)
                + 0.03 * sin(seed.w * 4.7 * p.t + seed.phase * 3)
            let breath: Double = 0.05 * s.doze * sin(p.t * 2.0 + seed.phase * 0.3)   // the sleeper's slow one
            var goal = seed.len * R * (1 + jitter * calm + breath)
            goal *= 1 + s.puff
            // trailing arms stretch behind a lane change
            goal += 0.30 * R * max(0, -cos(a) * p.sway)
            // hanging arms dangle in the air
            if air { goal += 0.22 * R * max(0, sin(a)) * min(1, p.lift / 0.5) }
            // asleep, the arms give in to gravity: the ones pointing up shorten, the ones hanging down lengthen
            goal += s.doze * R * (-0.34 * max(0, -sin(a)) + 0.10 * max(0, sin(a)))
            if dead { goal = seed.len * R * 0.5 }
            if landed { s.vel[i] += 2.2 }
            s.vel[i] += (-k * (s.len[i] - goal) - damp * s.vel[i]) * dt
            s.len[i] += s.vel[i] * dt
            s.len[i] = max(R * 0.3, s.len[i])
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
    /// Frames per second; the status pill's tiny one doesn't need the display's rate.
    var fps: Double? = nil
    @State private var state = BlobState()

    var body: some View {
        TimelineView(.animation(minimumInterval: fps.map { 1 / $0 }, paused: !running)) { tl in
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
