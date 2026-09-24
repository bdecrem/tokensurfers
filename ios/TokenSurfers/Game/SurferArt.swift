import SwiftUI

/// The surfer: Splat, the inflatable tube man from `misc/splat-back-smooth.svg`
/// (back, for the runner) and `misc/splat.svg` (front, for Home and the cards).
/// A sticker: every part has a white paper edge over an ink outline. The
/// orange tube wears a crown of eight rays (the splat), a token on a spring
/// antenna, a goggles strap, and a `>_` patch. Everything is drawn in the SVG's
/// own coordinates (y down, feet on y = 532) and animated the way the rig in
/// `misc/splat-back-rig.svg` intends, but softer: the tube bends like an air
/// dancer (base planted, top whipping, leaning into lane changes), the arms curl
/// from the shoulder out, the rays flutter, the antenna springs.
struct SurferPose {
    var phase: Double = 0          // run cycle, radians
    var lift: Double = 0           // height above the surface it stands on (world units)
    var vy: Double = 0
    var rolling: Double = 0        // seconds of roll left
    var rollSpin: Double = 0       // radians (unused by the tube; kept for the renderer)
    var lean: Double = 0           // radians (stumble)
    var sinceLanded: Double = 10
    var dead: Double = -1          // seconds since the crash; < 0 = alive
    var t: Double = 0              // clock for the flop
    var front = false
    var mood: Mood = .happy
    var speed: Double = 0.5        // 0..1, how hard the tube flops
    var sway: Double = 0           // -1..1, lane-change velocity; the top trails behind
    var energy: Double = 1         // 0 = limp, 1 = a full air dancer (Home, the Studio avatar)
    var running = true             // feet stepping

    enum Mood { case happy, wow, dead, cool }
}

enum SurferArt {
    /// World units per drawing unit (the SVG's px).
    static let k = 0.00366
    static let groundY = 532.0
    static let centerX = 214.0
    /// Standing height from the sole to the top of the token, for layout.
    static let height = (groundY - 57) * k

    static let ink = Color(hex: 0x1D1530)
    static let armFill = Color(hex: 0xF57A3F)
    static let armLight = Color(hex: 0xFFB98A)
    static let hand = Color(hex: 0xE0602A)
    static let gold = Color(hex: 0xF5C542)
    static let goldRing = Color(hex: 0xDDA127)
    static let diamond = Color(hex: 0xE8703A)
    static let green = Color(hex: 0x7CF29A)
    static let purple = Color(hex: 0x7B45D6)
    static let mouth = Color(hex: 0x2A1216)
    static let blush = Color(hex: 0xFF6F87)
    static let bodyGrad = Gradient(stops: [.init(color: Color(hex: 0xFF9A5A), location: 0),
                                           .init(color: Color(hex: 0xF4733B), location: 0.5),
                                           .init(color: Color(hex: 0xD5521F), location: 1)])
    static let hairGrad = Gradient(stops: [.init(color: Color(hex: 0xE5552A), location: 0),
                                           .init(color: Color(hex: 0xFF8A3D), location: 0.55),
                                           .init(color: Color(hex: 0xFFD24A), location: 1)])
    static let lensGrad = Gradient(stops: [.init(color: Color(hex: 0x241A45), location: 0),
                                           .init(color: Color(hex: 0x7B45D6), location: 0.55),
                                           .init(color: Color(hex: 0xFF8A5C), location: 1)])

    /// `origin` is the ground point under the character on screen; `unit` is
    /// pixels per world unit.
    static func draw(_ ctx: inout GraphicsContext, origin: CGPoint, unit: CGFloat, pose p: SurferPose) {
        var c = ctx
        c.translateBy(x: origin.x, y: origin.y)
        let s = unit * k
        let sh = max(0.35, 1 - p.lift * 0.22)
        c.fill(Path(ellipseIn: CGRect(x: -104 * s * sh, y: -12 * s * sh, width: 208 * s * sh, height: 24 * s * sh)),
               with: .color(ink.opacity(0.24)))
        c.translateBy(x: 0, y: -p.lift * unit)
        c.scaleBy(x: s, y: s)
        c.translateBy(x: -centerX, y: -groundY)

        if p.dead >= 0 { drawDead(&c, p); return }

        var body = c
        if p.rolling > 0 {
            // deflated: the tube sags into a crumple and scoots under the gate
            let wob = sin(p.t * 26) * 0.04
            around(&body, centerX, groundY) { $0.scaleBy(x: 1.22 + wob, y: 0.5 - wob) }
            drawStreaks(&c)
        } else {
            let air = p.lift > 0.03
            let squash = p.sinceLanded < 0.14 ? 1 - (0.14 - p.sinceLanded) * 1.3 : 1.0
            let sy = squash * (air ? 1.06 : 1.0)
            around(&body, centerX, groundY) {
                $0.rotate(by: .radians(p.lean * 0.8))
                $0.scaleBy(x: 1 / sy, y: sy)
            }
        }
        let rig = Rig(pose: p)
        figure(&body, rig)
    }

    private static func around(_ c: inout GraphicsContext, _ x: Double, _ y: Double, _ f: (inout GraphicsContext) -> Void) {
        c.translateBy(x: x, y: y)
        f(&c)
        c.translateBy(x: -x, y: -y)
    }

    // MARK: the rig

    /// Every moving number of one frame.
    struct Rig {
        var t = 0.0
        var front = false
        var mood: SurferPose.Mood = .happy
        var flopA = 9.0            // drawing px of sway at the top of the tube
        var flopW = 8.0            // rad/s
        var lean = 0.0             // px at the top, steady
        var armBase = (-10.0, 10.0) // degrees, left / right; + is clockwise
        var armAmp = 16.0
        var armW = 7.0
        var rayAmp = 6.0
        var antennaAmp = 10.0
        var footLift = (0.0, 0.0)
        var hairFlat = 1.0

        init() {}

        init(pose p: SurferPose) {
            t = p.t
            front = p.front
            mood = p.mood
            let air = p.lift > 0.03
            let e = p.energy
            lean = -max(-1, min(1, p.sway)) * 46
            if p.rolling > 0 {
                flopA = 14; flopW = 18
                armBase = (-78, 78); armAmp = 10; armW = 16
                rayAmp = 14; antennaAmp = 20; hairFlat = 0.8
            } else if air {
                flopA = 7; flopW = 10
                armBase = (18, -18); armAmp = 14; armW = 12
                rayAmp = 10; antennaAmp = 16
                footLift = (16, 12)
            } else {
                flopA = (8 + p.speed * 8) * e
                flopW = 6 + p.speed * 4
                armBase = (-10, 10)
                armAmp = (14 + p.speed * 10) * e
                armW = 6 + p.speed * 3
                rayAmp = 6 * e + 2
                antennaAmp = 10 * e + 2
                if p.running {
                    let a = sin(p.phase), b = sin(p.phase + .pi)
                    footLift = (max(0, a) * 26, max(0, b) * 26)
                }
            }
        }

        /// Sideways offset of the tube at height y: the base is planted, the top whips.
        func bend(_ y: Double) -> Double {
            let u = max(0, min(1.45, (490 - y) / 290))
            return flopA * sin(flopW * t - u * 2.2) * pow(u, 1.4) + lean * u * u
        }
        /// Radians the tube leans at height y (+ = clockwise on screen).
        func tilt(_ y: Double) -> Double { atan2(bend(y - 3) - bend(y + 3), 6) }
        func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x + bend(y), y: y) }
    }

    /// A part riding the tube at height y: moved with the bend, turned with its slope.
    private static func attach(_ c: GraphicsContext, _ r: Rig, at y: Double, pivotX: Double = centerX) -> GraphicsContext {
        var a = c
        a.translateBy(x: pivotX + r.bend(y), y: y)
        a.rotate(by: .radians(r.tilt(y)))
        a.translateBy(x: -pivotX, y: -y)
        return a
    }

    private static func rotate(_ p: CGPoint, about o: CGPoint, deg: Double) -> CGPoint {
        let a = deg * .pi / 180
        let dx = p.x - o.x, dy = p.y - o.y
        return CGPoint(x: o.x + dx * cos(a) - dy * sin(a), y: o.y + dx * sin(a) + dy * cos(a))
    }

    // MARK: parts, as paths in drawing space

    private static func bodyPath(_ r: Rig) -> Path {
        var p = Path()
        p.move(to: r.P(162, 488))
        p.addCurve(to: r.P(176, 270), control1: r.P(150, 400), control2: r.P(180, 330))
        p.addCurve(to: r.P(226, 198), control1: r.P(174, 225), control2: r.P(196, 198))
        p.addCurve(to: r.P(268, 270), control1: r.P(256, 198), control2: r.P(272, 225))
        p.addCurve(to: r.P(266, 488), control1: r.P(266, 330), control2: r.P(256, 400))
        p.addQuadCurve(to: r.P(162, 488), control: r.P(214, 502))
        p.closeSubpath()
        return p
    }

    /// One arm: the SVG's path, each point turned about the shoulder a little
    /// more than the one before it, so the wave curls outward like a tube.
    private struct Arm { var path: Path; var hand: CGPoint; var endAngle: Double }

    private static func arm(_ r: Rig, left: Bool) -> Arm {
        let pts: [CGPoint] = left
            ? [CGPoint(x: 190, y: 305), CGPoint(x: 148, y: 312), CGPoint(x: 128, y: 275), CGPoint(x: 118, y: 245),
               CGPoint(x: 108, y: 215), CGPoint(x: 94, y: 190), CGPoint(x: 104, y: 152), CGPoint(x: 104, y: 146)]
            : [CGPoint(x: 256, y: 300), CGPoint(x: 296, y: 310), CGPoint(x: 306, y: 282), CGPoint(x: 316, y: 258),
               CGPoint(x: 326, y: 234), CGPoint(x: 330, y: 222), CGPoint(x: 336, y: 204), CGPoint(x: 336, y: 198)]
        let f: [Double] = [0, 0.3, 0.5, 0.6, 0.75, 0.9, 1, 1]
        let shoulder = pts[0]
        let base = left ? r.armBase.0 : r.armBase.1
        let ph = left ? 0.0 : 1.3
        let torso = r.tilt(shoulder.y) * 180 / .pi
        let dx = r.bend(shoulder.y)
        var q: [CGPoint] = []
        var endAngle = 0.0
        for (i, p) in pts.enumerated() {
            let wave = r.armAmp * sin(r.armW * r.t + ph - f[i] * 1.7) * (0.55 + 0.45 * f[i])
            let a = base + wave + torso
            if i == pts.count - 1 { endAngle = a }
            var m = rotate(p, about: shoulder, deg: a)
            m.x += dx
            q.append(m)
        }
        var path = Path()
        path.move(to: q[0])
        path.addCurve(to: q[3], control1: q[1], control2: q[2])
        path.addCurve(to: q[6], control1: q[4], control2: q[5])
        return Arm(path: path, hand: q[7], endAngle: endAngle)
    }

    private static let rayTips: [(Double, Double)] = [(181, 202), (175, 176), (185, 146), (208, 128),
                                                      (244, 128), (267, 146), (277, 176), (271, 202)]

    private static func raysPath(_ r: Rig) -> Path {
        let root = CGPoint(x: 226, y: 212)
        var p = Path()
        for (i, tip) in rayTips.enumerated() {
            let flat = CGPoint(x: root.x + (tip.0 - root.x) * (2 - r.hairFlat), y: root.y + (tip.1 - root.y) * r.hairFlat)
            let t = rotate(flat, about: root, deg: sin(r.t * 8 + Double(i)) * r.rayAmp)
            p.move(to: root)
            p.addLine(to: t)
        }
        return p
    }

    /// Antenna points: the spring whips more toward the token.
    private static func antenna(_ r: Rig) -> (path: Path, coin: CGPoint) {
        let root = CGPoint(x: 226, y: 200)
        let swing = sin(r.t * 9) * r.antennaAmp
        let lag = sin(r.t * 9 - 0.9) * r.antennaAmp * 0.6
        func m(_ x: Double, _ y: Double, _ f: Double) -> CGPoint { rotate(CGPoint(x: x, y: y), about: root, deg: swing * f + lag * f * f) }
        var p = Path()
        p.move(to: root)
        p.addQuadCurve(to: m(230, 146, 0.5), control: m(214, 170, 0.3))
        p.addQuadCurve(to: m(226, 98, 0.95), control: m(246, 122, 0.75))
        return (p, m(226, 82, 1))
    }

    private static func circle(_ c: CGPoint, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    private static func round(_ w: Double) -> StrokeStyle { StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round) }

    // MARK: the whole figure, layer by layer (the SVG's order)

    private static func figure(_ c: inout GraphicsContext, _ r: Rig) {
        let body = bodyPath(r)
        let armL = arm(r, left: true), armR = arm(r, left: false)
        var head = attach(c, r, at: 205, pivotX: 226)
        let rays = raysPath(r)
        let ant = antenna(r)
        let shaka = r.front && r.mood != .dead
        let thumb = shaka ? rotate(CGPoint(x: armR.hand.x - 23, y: armR.hand.y - 25), about: armR.hand, deg: armR.endAngle) : .zero
        let pinky = shaka ? rotate(CGPoint(x: armR.hand.x + 27, y: armR.hand.y - 15), about: armR.hand, deg: armR.endAngle) : .zero

        // 1. white sticker edge
        head.stroke(rays, with: .color(.white), style: round(40))
        head.stroke(ant.path, with: .color(.white), style: round(16))
        head.fill(circle(ant.coin, 25), with: .color(.white))
        for a in [armL, armR] {
            c.stroke(a.path, with: .color(.white), style: round(52))
            c.fill(circle(a.hand, 27), with: .color(.white))
        }
        if shaka {
            for f in [thumb, pinky] { c.stroke(line(armR.hand, f), with: .color(.white), style: round(26)) }
        }
        for left in [true, false] where footDown(r, left) { sneaker(&c, r, left: left, layer: .edge) }
        c.stroke(body, with: .color(.white), style: round(20))
        c.fill(body, with: .color(.white))

        // 2. one merged ink silhouette under the fills
        head.stroke(rays, with: .color(ink), style: round(29))
        for a in [armL, armR] {
            c.stroke(a.path, with: .color(ink), style: round(40))
            c.fill(circle(a.hand, 21.5), with: .color(ink))
        }
        c.stroke(body, with: .color(ink), style: round(7))
        c.fill(body, with: .color(ink))

        // 3. antenna + token
        head.stroke(ant.path, with: .color(ink), style: round(6))
        head.fill(circle(ant.coin, 17), with: .color(gold))
        head.stroke(circle(ant.coin, 17), with: .color(ink), lineWidth: 4.5)
        head.stroke(circle(ant.coin, 11), with: .color(goldRing), lineWidth: 3)
        var dia = Path()
        dia.move(to: CGPoint(x: ant.coin.x, y: ant.coin.y - 8)); dia.addLine(to: CGPoint(x: ant.coin.x + 6, y: ant.coin.y))
        dia.addLine(to: CGPoint(x: ant.coin.x, y: ant.coin.y + 8)); dia.addLine(to: CGPoint(x: ant.coin.x - 6, y: ant.coin.y))
        dia.closeSubpath()
        head.fill(dia, with: .color(diamond))

        // 4. fills
        head.stroke(rays, with: .linearGradient(hairGrad, startPoint: CGPoint(x: 0, y: 215), endPoint: CGPoint(x: 0, y: 115)), style: round(20))
        for (a, off) in [(armL, CGSize(width: -5, height: -3)), (armR, CGSize(width: -4, height: -5))] {
            c.stroke(a.path, with: .color(armFill), style: round(30))
            c.stroke(a.path.offsetBy(dx: off.width, dy: off.height), with: .color(armLight.opacity(0.75)), style: round(7))
        }
        c.fill(circle(armL.hand, 19), with: .color(hand))
        c.fill(circle(CGPoint(x: armL.hand.x - 6, y: armL.hand.y - 6), 5), with: .color(armLight.opacity(0.8)))
        if shaka {
            for f in [thumb, pinky] {
                c.stroke(line(armR.hand, f), with: .color(ink), style: round(18))
                c.stroke(line(armR.hand, f), with: .color(hand), style: round(10))
            }
            c.fill(circle(armR.hand, 18), with: .color(hand))
            c.stroke(circle(armR.hand, 18), with: .color(ink), lineWidth: 5)
            var curls = Path()
            let h = armR.hand
            curls.move(to: CGPoint(x: h.x - 8, y: h.y - 2)); curls.addQuadCurve(to: CGPoint(x: h.x + 8, y: h.y - 2), control: CGPoint(x: h.x, y: h.y - 7))
            curls.move(to: CGPoint(x: h.x - 7, y: h.y + 6)); curls.addQuadCurve(to: CGPoint(x: h.x + 7, y: h.y + 6), control: CGPoint(x: h.x, y: h.y + 1))
            c.stroke(curls, with: .color(ink), style: round(3))
        } else {
            c.fill(circle(armR.hand, 19), with: .color(hand))
            c.fill(circle(CGPoint(x: armR.hand.x - 6, y: armR.hand.y - 6), 5), with: .color(armLight.opacity(0.8)))
        }

        // 5. planted sneakers (a lifted one is drawn over the tube, it's nearer)
        for left in [true, false] where footDown(r, left) { sneaker(&c, r, left: left, layer: .fill) }

        // 6. the tube
        let mid = r.bend(340)
        c.fill(body, with: .linearGradient(bodyGrad, startPoint: CGPoint(x: 150 + mid, y: 0), endPoint: CGPoint(x: 272 + mid, y: 0)))
        var inside = c
        inside.clip(to: body)
        var hi = Path()
        hi.move(to: r.P(196, 226)); hi.addQuadCurve(to: r.P(176, 470), control: r.P(180, 330))
        inside.stroke(hi, with: .color(Color(hex: 0xFFC29A).opacity(0.7)), style: round(10))
        inside.stroke(hi, with: .color(Color(hex: 0xFFF1E4).opacity(0.8)), style: round(3))
        var hem = Path()
        hem.move(to: r.P(162, 488)); hem.addQuadCurve(to: r.P(266, 488), control: r.P(214, 502))
        c.stroke(hem, with: .color(ink), style: round(7))

        if r.front { face(&c, r, inside: inside) } else { back(&c, r, inside: inside) }

        for left in [true, false] where !footDown(r, left) {
            sneaker(&c, r, left: left, layer: .edge)
            sneaker(&c, r, left: left, layer: .fill)
        }
    }

    private static func line(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path(); p.move(to: a); p.addLine(to: b); return p
    }

    // MARK: back: goggles strap + the >_ patch

    private static func back(_ c: inout GraphicsContext, _ r: Rig, inside: GraphicsContext) {
        var strap = Path()
        strap.move(to: r.P(160, 256)); strap.addQuadCurve(to: r.P(280, 248), control: r.P(222, 268))
        inside.stroke(strap, with: .color(ink), style: round(11))
        c.stroke(line(r.P(165, 255), r.P(178, 257)), with: .color(ink), style: round(9))
        c.stroke(line(r.P(267, 251), r.P(281, 247)), with: .color(ink), style: round(9))
        let buckle = attach(c, r, at: 259, pivotX: 223)
        let b = Path(roundedRect: CGRect(x: 213, y: 253, width: 20, height: 13), cornerRadius: 4)
        buckle.fill(b, with: .color(purple))
        buckle.stroke(b, with: .color(ink), lineWidth: 3)

        terminal(attach(c, r, at: 335, pivotX: 219), x: 195, y: 318)
    }

    private static func terminal(_ c: GraphicsContext, x: Double, y: Double) {
        let box = Path(roundedRect: CGRect(x: x, y: y, width: 48, height: 34), cornerRadius: 9)
        c.fill(box, with: .color(ink))
        c.stroke(box, with: .color(Color(hex: 0x3A3060)), lineWidth: 3)
        var chev = Path()
        chev.move(to: CGPoint(x: x + 10, y: y + 10)); chev.addLine(to: CGPoint(x: x + 19, y: y + 17)); chev.addLine(to: CGPoint(x: x + 10, y: y + 24))
        c.stroke(chev, with: .color(green), style: round(4))
        c.stroke(line(CGPoint(x: x + 24, y: y + 25), CGPoint(x: x + 36, y: y + 25)), with: .color(green), style: round(4))
    }

    // MARK: front: shades, grin, blush, the chest terminal

    private static func face(_ c: inout GraphicsContext, _ r: Rig, inside: GraphicsContext) {
        terminal(attach(c, r, at: 355, pivotX: 221), x: 197, y: 338)
        let f = attach(c, r, at: 275, pivotX: 222)
        f.fill(Path(ellipseIn: CGRect(x: 178, y: 287.5, width: 20, height: 11)), with: .color(blush.opacity(0.5)))
        f.fill(Path(ellipseIn: CGRect(x: 249, y: 278.5, width: 14, height: 9)), with: .color(blush.opacity(0.5)))

        switch r.mood {
        case .dead:
            for (x, y) in [(198.0, 262.0), (244.0, 258.0)] {
                var xp = Path()
                xp.move(to: CGPoint(x: x - 9, y: y - 9)); xp.addLine(to: CGPoint(x: x + 9, y: y + 9))
                xp.move(to: CGPoint(x: x + 9, y: y - 9)); xp.addLine(to: CGPoint(x: x - 9, y: y + 9))
                f.stroke(xp, with: .color(ink), style: round(6))
            }
            f.stroke(line(CGPoint(x: 208, y: 305), CGPoint(x: 244, y: 300)), with: .color(ink), style: round(6))
            return
        case .wow:
            let o = Path(ellipseIn: CGRect(x: 215, y: 292, width: 20, height: 26))
            f.fill(o, with: .color(mouth))
            f.stroke(o, with: .color(ink), lineWidth: 4)
        default:
            var grin = Path()
            grin.move(to: CGPoint(x: 198, y: 300))
            grin.addQuadCurve(to: CGPoint(x: 256, y: 292), control: CGPoint(x: 228, y: 328))
            grin.addQuadCurve(to: CGPoint(x: 198, y: 300), control: CGPoint(x: 228, y: 308))
            grin.closeSubpath()
            f.fill(grin, with: .color(mouth))
            f.stroke(grin, with: .color(ink), style: round(4))
            var teeth = Path()
            teeth.move(to: CGPoint(x: 204, y: 302))
            teeth.addQuadCurve(to: CGPoint(x: 250, y: 297), control: CGPoint(x: 228, y: 309))
            teeth.addQuadCurve(to: CGPoint(x: 240, y: 306), control: CGPoint(x: 246, y: 303))
            teeth.addQuadCurve(to: CGPoint(x: 207, y: 305), control: CGPoint(x: 224, y: 311))
            teeth.closeSubpath()
            f.fill(teeth, with: .color(.white))
            var dimple = Path()
            dimple.move(to: CGPoint(x: 256, y: 292)); dimple.addQuadCurve(to: CGPoint(x: 263, y: 284), control: CGPoint(x: 262, y: 290))
            f.stroke(dimple, with: .color(ink), style: round(3))
        }

        var shades = Path()
        shades.move(to: CGPoint(x: 172, y: 250))
        shades.addQuadCurve(to: CGPoint(x: 270, y: 238), control: CGPoint(x: 220, y: 238))
        shades.addLine(to: CGPoint(x: 268, y: 252))
        shades.addQuadCurve(to: CGPoint(x: 242, y: 278), control: CGPoint(x: 264, y: 276))
        shades.addQuadCurve(to: CGPoint(x: 222, y: 262), control: CGPoint(x: 226, y: 278))
        shades.addQuadCurve(to: CGPoint(x: 216, y: 262), control: CGPoint(x: 219, y: 258))
        shades.addQuadCurve(to: CGPoint(x: 192, y: 282), control: CGPoint(x: 210, y: 282))
        shades.addQuadCurve(to: CGPoint(x: 174, y: 262), control: CGPoint(x: 176, y: 280))
        shades.closeSubpath()
        f.fill(shades, with: .linearGradient(lensGrad, startPoint: CGPoint(x: 0, y: 240), endPoint: CGPoint(x: 0, y: 282)))
        f.stroke(shades, with: .color(ink), style: round(5))
        var bar = Path()
        bar.move(to: CGPoint(x: 172, y: 250)); bar.addQuadCurve(to: CGPoint(x: 270, y: 238), control: CGPoint(x: 220, y: 238))
        f.stroke(bar, with: .color(ink), style: round(8))
        for g in [[(190.0, 253.0), (198, 251), (188, 274), (182, 272)], [(238, 247), (244, 246), (235, 268), (230, 267)]] {
            var p = Path()
            p.move(to: CGPoint(x: g[0].0, y: g[0].1))
            for q in g.dropFirst() { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
            p.closeSubpath()
            f.fill(p, with: .color(.white.opacity(0.85)))
        }
    }

    // MARK: sneakers

    private enum SneakerLayer { case edge, fill }

    private static func footDown(_ r: Rig, _ left: Bool) -> Bool { (left ? r.footLift.0 : r.footLift.1) < 8 }

    /// Back view: heels and soles. Front view: the side-on toes of the SVG.
    /// A lifted foot rises and shows more sole.
    private static func sneaker(_ c: inout GraphicsContext, _ r: Rig, left: Bool, layer: SneakerLayer) {
        let lift = left ? r.footLift.0 : r.footLift.1
        var s = c
        s.translateBy(x: 0, y: 10 - lift)
        let sole = lift * 0.35
        if r.front {
            var shoe = Path()
            if left {
                shoe.move(to: CGPoint(x: 214, y: 512)); shoe.addLine(to: CGPoint(x: 214, y: 482))
                shoe.addQuadCurve(to: CGPoint(x: 202, y: 472), control: CGPoint(x: 213, y: 472))
                shoe.addLine(to: CGPoint(x: 176, y: 472))
                shoe.addQuadCurve(to: CGPoint(x: 166, y: 482), control: CGPoint(x: 168, y: 473))
                shoe.addQuadCurve(to: CGPoint(x: 150, y: 497), control: CGPoint(x: 164, y: 492))
                shoe.addQuadCurve(to: CGPoint(x: 144, y: 512), control: CGPoint(x: 142, y: 502))
            } else {
                shoe.move(to: CGPoint(x: 208, y: 512)); shoe.addLine(to: CGPoint(x: 208, y: 482))
                shoe.addQuadCurve(to: CGPoint(x: 220, y: 472), control: CGPoint(x: 209, y: 472))
                shoe.addLine(to: CGPoint(x: 246, y: 472))
                shoe.addQuadCurve(to: CGPoint(x: 256, y: 482), control: CGPoint(x: 254, y: 473))
                shoe.addQuadCurve(to: CGPoint(x: 272, y: 497), control: CGPoint(x: 258, y: 492))
                shoe.addQuadCurve(to: CGPoint(x: 278, y: 512), control: CGPoint(x: 280, y: 502))
            }
            shoe.closeSubpath()
            let soleRect = Path(roundedRect: CGRect(x: left ? 140 : 202, y: 508 - sole, width: 80, height: 14 + sole), cornerRadius: 7)
            switch layer {
            case .edge:
                s.stroke(shoe, with: .color(.white), style: round(16)); s.fill(shoe, with: .color(.white))
                s.stroke(soleRect, with: .color(.white), style: round(16)); s.fill(soleRect, with: .color(.white))
            case .fill:
                s.fill(shoe, with: .color(.white))
                s.stroke(shoe, with: .color(ink), style: round(5))
                var bolt = Path()
                if left {
                    bolt.move(to: CGPoint(x: 170, y: 498)); bolt.addLine(to: CGPoint(x: 186, y: 490))
                    bolt.addLine(to: CGPoint(x: 184, y: 497)); bolt.addLine(to: CGPoint(x: 198, y: 492))
                } else {
                    bolt.move(to: CGPoint(x: 252, y: 498)); bolt.addLine(to: CGPoint(x: 236, y: 490))
                    bolt.addLine(to: CGPoint(x: 238, y: 497)); bolt.addLine(to: CGPoint(x: 224, y: 492))
                }
                s.stroke(bolt, with: .color(diamond), style: round(4))
                s.fill(soleRect, with: .color(ink))
            }
        } else {
            let x0 = left ? 168.0 : 218.0
            let heel = Path(roundedRect: CGRect(x: x0, y: 476, width: 42, height: 36), cornerRadius: 11)
            let soleRect = Path(roundedRect: CGRect(x: x0 - 4, y: 508 - sole, width: 50, height: 14 + sole), cornerRadius: 7)
            switch layer {
            case .edge:
                s.stroke(heel, with: .color(.white), style: round(16)); s.fill(heel, with: .color(.white))
                s.stroke(soleRect, with: .color(.white), style: round(16)); s.fill(soleRect, with: .color(.white))
            case .fill:
                s.fill(heel, with: .color(.white))
                s.stroke(heel, with: .color(ink), style: round(5))
                let tab = Path(roundedRect: CGRect(x: x0 + 16, y: 492, width: 10, height: 16), cornerRadius: 4)
                s.fill(tab, with: .color(diamond))
                s.stroke(tab, with: .color(ink), lineWidth: 3)
                s.fill(soleRect, with: .color(ink))
            }
        }
    }

    // MARK: roll + crash

    private static func drawStreaks(_ c: inout GraphicsContext) {
        for k in 0..<3 {
            let y = 430 + Double(k) * 30
            c.stroke(line(CGPoint(x: 60, y: y), CGPoint(x: 120 - Double(k) * 10, y: y)), with: .color(.white.opacity(0.75)), style: round(8))
            c.stroke(line(CGPoint(x: 310 + Double(k) * 10, y: y), CGPoint(x: 370, y: y)), with: .color(.white.opacity(0.75)), style: round(8))
        }
    }

    private static func drawDead(_ c: inout GraphicsContext, _ p: SurferPose) {
        let d = p.dead
        let arc = d < 1 ? 1.5 * sin(d * .pi) : 0
        var s = c
        s.translateBy(x: 0, y: -arc / k)
        around(&s, centerX, 340) { $0.rotate(by: .radians(min(d, 1.1) * 8.5)) }
        var r = Rig()
        r.t = p.t
        r.front = true
        r.mood = .dead
        r.flopA = 16; r.flopW = 5
        r.armBase = (-40, 40); r.armAmp = 18; r.armW = 9
        r.rayAmp = 14; r.antennaAmp = 22
        r.footLift = (0, 0)
        figure(&s, r)
    }
}

/// The surfer as a SwiftUI view: front view dancing in place, for Home, the
/// cards and the Studio. `unit` = pixels per world unit; `energy` 0…1 is how
/// hard the tube dances.
struct SurferHero: View {
    var unit: CGFloat = 80
    var mood: SurferPose.Mood = .happy
    var running = true
    var front = true
    var energy: Double = 1

    var body: some View {
        TimelineView(.animation(paused: !running)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                var p = SurferPose()
                p.t = running ? t : 0.4
                p.phase = running ? t * (4 + 4 * energy) : 0
                p.front = front
                p.mood = mood
                p.speed = running ? 0.35 * energy : 0
                p.energy = running ? energy : 0.2
                p.running = running && energy > 0.4
                SurferArt.draw(&ctx, origin: CGPoint(x: size.width / 2, y: size.height - unit * 0.1), unit: unit, pose: p)
            }
        }
        .frame(width: unit * 1.7, height: unit * (SurferArt.height + 0.14))
    }
}
