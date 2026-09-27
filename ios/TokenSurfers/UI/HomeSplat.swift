import SwiftUI
import UIKit

/// The Splat on Home (2026-09-25): the track's blob with a face and a little
/// brain, living in the top right corner like a pet on a shelf.
///
/// Its day: awake, it spins and fidgets, blinks, looks around, and every few
/// seconds does a bit — a hop with a crouch first, a shiver, a double take, a
/// spin burst, a wiggle. After half a minute or so it yawns (all arms stretch,
/// the mouth goes round), the lids get heavy, it nods off twice and slumps
/// into sleep: the spin stops, the arms give in to gravity, the colour cools,
/// it breathes slowly, z's float up. It wakes on its own with a big stretch
/// and a shake, or gets STARTLED awake — a tap, or the composer being focused
/// — with a jump, all arms out, wide eyes, a "!" and a white flash, then looks
/// left, right, and settles. Awake, a tap pokes it: pushed away from the
/// finger, a squish that wobbles back, a spin kick the way it was hit, a happy
/// squint, sparks and a ring. Too many pokes make it dizzy: spinning wildly,
/// wobbling, spiral gaze, stars around the head, then a shake to clear it.
/// Hold it and it's picked up: rises to the finger, dangles, kicks, looks up
/// at you; let go and it drops with a bounce and a sulk. When the composer has
/// text it perks up and keeps glancing at the card.
///
/// One class, stepped once per frame from the view's Canvas (the same pattern
/// as `BlobState`); the body is `BlobArt.draw` with the brain's overrides.
final class SplatBrain {
    enum Mode { case awake, drowsy, asleep, waking, startled, dizzy, held, falling }
    enum Mouth { case smile, grin, o, flat, wavy }
    enum Bit { case hop, shiver, doubleTake, spinBurst, yawn, wiggle }

    let state = BlobState()
    private(set) var mode: Mode = .awake
    private(set) var modeT = 0.0
    private var now = 0.0
    private var lastT = -1.0
    private var rng: SeededRandom

    // the sleep cycle
    private var sleepIn: Double
    private var napLeft = 0.0
    private var yawns = 0
    private var zIn = 0.6
    private var mumble = 0.0
    private var sulk = 0.0

    // the body
    private(set) var lift = 0.0
    private var vy = 0.0
    private(set) var sinceLanded = 10.0
    private(set) var lean = 0.0
    private var leanV = 0.0
    private var jitter = 0.0, jitterHz = 20.0      // the shake: amplitude (radians), decays
    private var wobble = 0.0                         // the dizzy sway
    private(set) var offset = CGPoint.zero           // displacement from home, world units, y down
    private var offV = CGPoint.zero
    private var squashTarget = CGSize(width: 1, height: 1)
    private var squashV = CGSize.zero
    private(set) var sway = 0.0
    private var sinkTarget = 0.0
    private var dozeTarget = 0.0
    private var tintTarget = 0.0

    // the face
    private(set) var gaze = CGPoint.zero
    private var gazeTarget = CGPoint.zero, gazeIn = 1.0
    private(set) var lid = 0.0
    private var lidTarget = 0.0, lidSpeed = 14.0
    private var blinkIn = 2.5, blinkClose = 0.0
    private(set) var eyeScale = 1.0, pupilScale = 1.0
    private(set) var mouth: Mouth = .smile
    private(set) var mouthOpen = 0.0
    private var mouthTarget = 0.0
    private(set) var happy = 0.0                     // > 0.5: the eyes squint into arcs
    private(set) var cheeks = 0.0

    // bits and the outside world
    private var bit: Bit?
    private var bitT = 0.0
    private var bitIn: Double
    private var dizzy = 0.0
    private var holdT = 0.0
    private var finger: CGPoint?
    private var grab = CGPoint.zero
    private var grabPending = false
    var excited = false { didSet { if excited != oldValue { excitement(excited) } } }

    /// TS_SPLAT="3:poke,3.4:poke,9:hold,11:release,14:nap" — a script of what
    /// to do at what second (poke, hold = pick up, drag = move the hand, release,
    /// nap = fall asleep now, wake = end the nap now), so the reactions can be
    /// screenshotted in a simulator that has no finger.
    private var script: [(at: Double, verb: String)] = {
        guard let raw = ProcessInfo.processInfo.environment["TS_SPLAT"] else { return [] }
        return raw.split(separator: ",").compactMap { item in
            let parts = item.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let at = Double(parts[0]) else { return nil }
            return (at, String(parts[1]).trimmingCharacters(in: .whitespaces))
        }.sorted { $0.at < $1.at }
    }()
    private var scriptT = 0.0
    var scripted: Bool { ProcessInfo.processInfo.environment["TS_SPLAT"] != nil }
    private var scriptHand = CGPoint(x: 0.25, y: 0.1)

    private func runScript(_ dt: Double) {
        guard !script.isEmpty else { return }
        scriptT += dt
        while let next = script.first, next.at <= scriptT {
            script.removeFirst()
            switch next.verb {
            case "poke": poke(at: CGPoint(x: 0.3, y: 0.05))
            case "pokeleft": poke(at: CGPoint(x: -0.3, y: 0.1))
            case "hold": scriptHand = CGPoint(x: 0.05, y: -0.05); hold(at: nil); hold(at: scriptHand)
            case "drag": scriptHand = CGPoint(x: scriptHand.x - 0.35, y: scriptHand.y - 0.3); hold(at: scriptHand)
            case "release": release()
            case "nap": if mode == .awake { sleepIn = 0; endBit() }
            case "wake": if mode == .asleep { napLeft = 0 }
            case "excite": excited = true
            case "calm": excited = false
            default: break
            }
        }
        if mode == .held, let f = finger { hold(at: f) }
    }

    // particles, in world units from the body's centre (y down)
    struct Glyph { var text: String; var pos: CGPoint; var vel: CGPoint; var age = 0.0; var life: Double; var size: Double; var color: Color; var wobble: Double; var pop = false }
    struct Spark { var pos: CGPoint; var vel: CGPoint; var age = 0.0; var life: Double; var color: Color; var spin: Double }
    struct Ring { var pos: CGPoint; var age = 0.0; var life: Double; var color: Color }
    private(set) var glyphs: [Glyph] = []
    private(set) var sparks: [Spark] = []
    private(set) var rings: [Ring] = []

    init() {
        rng = SeededRandom(seed: UInt64(Date().timeIntervalSince1970 * 1000) | 1)
        sleepIn = 22 + rng.unit() * 26
        bitIn = 4 + rng.unit() * 5
        state.bodyScale = 1.5
        state.hideToken = true
    }

    var shake: Double { jitter * sin(now * jitterHz * 2 * .pi) + wobble }
    var sleeping: Bool { mode == .asleep || mode == .drowsy || (mode == .waking && modeT < 0.3) }
    private var baseMouth: Mouth { sulk > 0 ? .flat : (excited ? .grin : .smile) }

    // MARK: - the clock

    func step(_ t: Double) {
        if lastT < 0 { lastT = t }
        let dt = min(0.05, max(0, t - lastT))
        lastT = t
        now = t
        guard dt > 0 else { return }
        modeT += dt
        holdT = mode == .held ? holdT + dt : 0
        runScript(dt)

        switch mode {
        case .awake: awake(dt)
        case .drowsy: drowsy(dt)
        case .asleep: asleep(dt)
        case .waking: waking(dt)
        case .startled: startled(dt)
        case .dizzy: dizzyStep(dt)
        case .held: heldStep(dt)
        case .falling: fallingStep(dt)
        }
        stepBit(dt)
        physics(dt)
        face(dt)
        particles(dt)
    }

    // MARK: - modes

    private func enter(_ m: Mode) {
        mode = m
        modeT = 0
        switch m {
        case .awake:
            lidSpeed = 14; state.fidget = 1; state.spinScale = 1
            bitIn = max(bitIn, 2.5)
        case .drowsy:
            lidSpeed = 3; endBit(); state.puff = 0
        case .asleep:
            lidSpeed = 3; napLeft = 13 + rng.unit() * 17; zIn = 0.5
            mouth = .flat; mouthTarget = 0
            state.tint = (0.70, 0.50, 0.58)
        case .waking:
            lidSpeed = 4
        case .startled:
            lidSpeed = 30; endBit(); happy = 0; cheeks = 0
            glyphs.removeAll { $0.text.lowercased() == "z" }
            lift = 0; vy = 0
            jump(2.7)
            squashV = CGSize(width: -2, height: 3)
            for i in state.vel.indices { state.vel[i] += 5 + rng.unit() * 3 }
            state.spinKick += 15
            state.flash = 1
            state.puff = 0
            tintTarget = 0
            glyphs.append(Glyph(text: "!", pos: CGPoint(x: -0.30, y: -0.42), vel: CGPoint(x: -0.05, y: -0.10), life: 1.0, size: 0.27, color: Theme.yellow, wobble: 0, pop: true))
            rings.append(Ring(pos: .zero, life: 0.45, color: .white))
            haptic(.rigid)
        case .dizzy:
            endBit(); happy = 0; cheeks = 0
            state.spinKick += 22
            mouth = .wavy; mouthTarget = 0
            state.tint = (0.80, 0.78, 0.42)
            haptic(.medium)
        case .held:
            lidSpeed = 14; endBit(); state.puff = 0
            glyphs.removeAll { $0.text.lowercased() == "z" }
            lift = 0; vy = 0
            tintTarget = 0
            haptic(.medium)
        case .falling:
            break
        }
    }

    private func wakeUp() {
        yawns = 0
        sleepIn = 20 + rng.unit() * 26
        bitIn = 4 + rng.unit() * 5
        dozeTarget = 0
        sinkTarget = 0
        tintTarget = 0
        squashTarget = CGSize(width: 1, height: 1)
    }

    private func awake(_ dt: Double) {
        dozeTarget = 0
        sinkTarget = 0
        state.spinScale = excited ? 1.35 : 1
        state.fidget = excited ? 1.6 : 1
        if !excited && finger == nil { sleepIn -= dt }
        dizzy = max(0, dizzy - 0.3 * dt)
        sulk = max(0, sulk - dt)
        if bit == nil {
            bitIn -= dt
            if bitIn <= 0 {
                startBit(pickBit())
                bitIn = 6 + rng.unit() * 8
            }
            if mouth != baseMouth && mouthOpen < 0.05 { mouth = baseMouth }
        }
        if sleepIn <= 0 && bit == nil && finger == nil && lift == 0 { enter(.drowsy) }
    }

    private func drowsy(_ dt: Double) {
        // 4.8 s: a yawn, the lids get heavy, the spin winds down, two nods
        let u = modeT
        dozeTarget = min(0.65, u / 4.8 * 0.65)
        state.spinScale = max(0.2, 1 - u / 4)
        state.fidget = 0.5
        tintTarget = 0.15 * min(1, u / 4.8)
        if u < 0.05 && bit == nil { startBit(.yawn) }
        var s = 0.0, l = 0.55
        for n in [1.9, 3.4] {
            let v = u - n
            guard v >= 0 && v < 1.2 else { continue }
            if v < 0.85 { let k = smooth(v / 0.85); s = 0.10 * k; l = 0.55 + 0.45 * k }          // sinks, eyes closing
            else { let k = smooth((v - 0.85) / 0.35); s = 0.10 * (1 - k); l = 0.25 + 0.3 * k }   // jerks back up, eyes open a crack
        }
        sinkTarget = s
        if bit == nil { lidTarget = l }
        gazeTarget = CGPoint(x: 0.1, y: 0.4)
        if u > 4.8 { enter(.asleep) }
    }

    private func asleep(_ dt: Double) {
        dozeTarget = 1
        state.spinScale = 0
        state.fidget = 0.05
        sinkTarget = 0.09
        tintTarget = 0.4
        lidTarget = 1
        gazeTarget = .zero
        squashTarget = CGSize(width: 1.10, height: 0.90)
        napLeft -= dt
        zIn -= dt
        if zIn <= 0 {
            zIn = 1.0 + rng.unit() * 0.7
            let big = rng.unit() < 0.3
            glyphs.append(Glyph(text: big ? "Z" : "z", pos: CGPoint(x: -0.18, y: -0.24), vel: CGPoint(x: -0.11, y: -0.24),
                                life: 2.6, size: big ? 0.19 : 0.13, color: big ? Theme.yellow : .white, wobble: rng.unit() * 6.28))
        }
        // a mumble now and then
        if mumble > 0 { mumble -= dt; if mumble <= 0 { mouth = .flat } }
        else if napLeft > 1.5, rng.unit() < dt * 0.12 { mouth = .wavy; mumble = 0.7 }
        if napLeft <= 0 { enter(.waking) }
    }

    private func waking(_ dt: Double) {
        let u = modeT
        state.fidget = 0.3
        if u < 0.6 {
            // the eyes crack open and the big stretch begins: every arm out, tall, rising
            let k = smooth(u / 0.6)
            dozeTarget = 1 - 0.6 * k
            lidTarget = 1 - 0.55 * k
            state.puff = 0.38 * k
            mouth = .o; mouthTarget = k
            squashTarget = CGSize(width: 1.10 - 0.20 * k, height: 0.90 + 0.24 * k)
            sinkTarget = 0.09 - 0.15 * k
            tintTarget = 0.35 * (1 - k)
            state.spinScale = 0
        } else if u < 1.15 {
            gazeTarget = CGPoint(x: 0, y: -0.5)
        } else if u < 1.5 {
            // let go: a shake, the spin revs up
            let k = smooth((u - 1.15) / 0.35)
            if u - dt < 1.15 { jitter = 0.2; jitterHz = 17; state.spinKick += 6; squashV = CGSize(width: 2, height: -2) }
            state.puff = 0.38 * (1 - k)
            mouthTarget = 1 - k
            squashTarget = CGSize(width: 1, height: 1)
            sinkTarget = 0
            dozeTarget = 0.4 * (1 - k)
            lidTarget = 0.45 * (1 - k)
            state.spinScale = k
        } else {
            mouth = .smile; state.puff = 0; lidTarget = 0; state.spinScale = 1
            wakeUp()
            enter(.awake)
        }
    }

    private func startled(_ dt: Double) {
        let u = modeT
        dozeTarget = 0; sinkTarget = 0
        squashTarget = CGSize(width: 1, height: 1)
        state.spinScale = 1; state.fidget = 3
        lidTarget = 0
        let wide = max(0, 1 - u / 1.3)
        eyeScale = 1 + 0.35 * wide
        pupilScale = 1 - 0.45 * wide
        mouth = .o; mouthTarget = max(0, 0.9 - u * 0.7)
        if u - dt < 0.45 && u >= 0.45 { gazeTarget = CGPoint(x: -0.95, y: 0.1); gazeIn = 12 }
        if u - dt < 0.8 && u >= 0.8 { gazeTarget = CGPoint(x: 0.95, y: -0.1); gazeIn = 12 }
        if u - dt < 1.15 && u >= 1.15 { gazeTarget = finger ?? CGPoint(x: 0, y: -0.3); gazeIn = 10 }
        if u > 1.7 {
            eyeScale = 1; pupilScale = 1; mouth = baseMouth; mouthTarget = 0
            wakeUp()
            sleepIn = 18 + rng.unit() * 20
            enter(.awake)
        }
    }

    private func dizzyStep(_ dt: Double) {
        let u = modeT
        tintTarget = 0.35
        let env = u < 2.4 ? 1.0 : max(0, 1 - (u - 2.4) / 0.4)
        wobble = sin(now * 7.5) * 0.24 * env
        gaze = CGPoint(x: cos(now * 10) * 0.85, y: sin(now * 10) * 0.85)
        lidTarget = 0.25
        if u > 2.4 && u - dt <= 2.4 { jitter = 0.3; jitterHz = 20 }
        if u > 2.9 {
            wobble = 0; tintTarget = 0; dizzy = 0; mouth = baseMouth; lidTarget = 0
            enter(.awake)
        }
    }

    private func heldStep(_ dt: Double) {
        dozeTarget = 0; sinkTarget = 0
        squashTarget = CGSize(width: 1, height: 1)
        let bored = holdT > 3
        lidTarget = bored ? 0.5 : 0.1
        state.spinScale = 0.35
        state.fidget = bored ? 0.8 : 2.5
        mouth = bored ? .flat : .o
        mouthTarget = bored ? 0 : 0.5
        eyeScale = 1.1; pupilScale = bored ? 1 : 0.8
        if let f = finger {
            let target = CGPoint(x: max(-1.35, min(0.6, f.x - grab.x)), y: max(-1.15, min(0.3, f.y - grab.y)))
            let k = 140.0, d = 14.0
            offV.x += (-k * (offset.x - target.x) - d * offV.x) * dt
            offV.y += (-k * (offset.y - target.y) - d * offV.y) * dt
            offset.x += offV.x * dt
            offset.y += offV.y * dt
        }
        sway = max(-1, min(1, offV.x / 3))
        gazeTarget = CGPoint(x: 0, y: -0.45)
    }

    private func fallingStep(_ dt: Double) {
        offV.y += 14 * dt
        offV.x -= offV.x * min(1, 2 * dt)
        offset.x += offV.x * dt
        offset.y += offV.y * dt
        sway = max(-1, min(1, offV.x / 4))
        eyeScale = 1.2; pupilScale = 0.7; mouth = .o; mouthTarget = 0.8
        if offset.y >= 0 {
            offset.y = 0
            sinceLanded = 0
            if offV.y > 1.8 {
                for i in state.vel.indices { state.vel[i] += 1.5 }
                offV.y = -offV.y * 0.32
                squashV.height -= 2.5; squashV.width += 1.2
                haptic(.rigid)
            } else {
                offV.y = 0
                eyeScale = 1; pupilScale = 1; mouthTarget = 0
                sulk = 1.4; mouth = .flat
                gazeTarget = CGPoint(x: 0, y: -0.6); gazeIn = 6
                jitter = 0.12; jitterHz = 14
                wakeUp()
                enter(.awake)
                haptic(.light)
            }
        }
    }

    // MARK: - bits

    private func pickBit() -> Bit {
        if sleepIn < 14 && rng.unit() < 0.4 { return .yawn }
        switch rng.int(5) {
        case 0: return .hop
        case 1: return .shiver
        case 2: return .doubleTake
        case 3: return .spinBurst
        default: return .wiggle
        }
    }

    private func startBit(_ b: Bit) {
        bit = b
        bitT = 0
        switch b {
        case .hop:
            squashV = CGSize(width: 1.5, height: -3)            // the crouch first
        case .shiver:
            jitter = 0.07; jitterHz = 26; lidTarget = 0.5
            state.tint = (0.62, 0.60, 0.78); tintTarget = 0.3
        case .doubleTake:
            gazeTarget = CGPoint(x: -0.9, y: 0.1); gazeIn = 9
        case .spinBurst:
            state.spinKick += 10; squashV.width -= 2.5; happy = 1
        case .yawn:
            mouth = .o
            yawns += 1
            if yawns >= 2 { sleepIn = min(sleepIn, 2.5) }
        case .wiggle:
            jitter = 0.14; jitterHz = 6.5; happy = 1; cheeks = 1; mouth = .grin
        }
    }

    private func stepBit(_ dt: Double) {
        guard let b = bit else { return }
        bitT += dt
        switch b {
        case .hop:
            if bitT >= 0.13 && bitT - dt < 0.13 { jump(2.3); squashV = CGSize(width: -1.5, height: 2.5); happy = 1 }
            if bitT > 0.4 && lift == 0 { endBit() }
        case .shiver:
            if bitT > 0.5 { tintTarget = 0; endBit() }
        case .doubleTake:
            if bitT >= 0.32 && bitT - dt < 0.32 { gazeTarget = CGPoint(x: 0.95, y: -0.1); gazeIn = 9; state.spinKick += 3; leanV -= 2 }
            if bitT > 0.95 { endBit() }
        case .spinBurst:
            if bitT > 0.8 { endBit() }
        case .yawn:
            let u = bitT
            let env = u < 0.5 ? smooth(u / 0.5) : u < 0.9 ? 1 : max(0, 1 - smooth((u - 0.9) / 0.5))
            mouthTarget = env
            state.puff = 0.32 * env
            lidTarget = 0.55 * env
            if u > 1.45 { endBit() }
        case .wiggle:
            if bitT > 0.9 { endBit() }
        }
    }

    private func endBit() {
        guard bit != nil else { return }
        bit = nil
        mouth = baseMouth
        mouthTarget = 0
        state.puff = 0
        if mode == .awake { lidTarget = 0 }
    }

    // MARK: - the outside world

    /// A tap, `at` in world units from the home centre (y down).
    func poke(at local: CGPoint) {
        switch mode {
        case .asleep, .drowsy, .waking:
            enter(.startled)
            return
        case .held, .falling, .startled, .dizzy:
            return
        default:
            break
        }
        // pushed away from the finger, a squish that wobbles back, a spin kick the way it was hit
        let len = max(0.05, hypot(local.x, local.y))
        let dir = CGPoint(x: local.x / len, y: local.y / len)
        offV.x -= dir.x * 2.6
        offV.y -= dir.y * 2.6
        if abs(dir.x) > abs(dir.y) { squashV.width -= 5; squashV.height += 2.5 } else { squashV.height -= 5; squashV.width += 2.5 }
        state.spinKick += local.x >= 0 ? 11 : -11
        endBit()
        happy = 1; cheeks = 1; mouth = .grin
        gazeTarget = CGPoint(x: dir.x * 0.9, y: dir.y * 0.7); gazeIn = 1.5
        for _ in 0..<10 {
            let a = rng.unit() * 2 * .pi, sp = 1.6 + rng.unit() * 1.6
            sparks.append(Spark(pos: local, vel: CGPoint(x: cos(a) * sp, y: sin(a) * sp - 1.0),
                                life: 0.55 + rng.unit() * 0.3, color: rng.unit() < 0.5 ? Theme.yellow : .white, spin: rng.unit() * 6.28))
        }
        rings.append(Ring(pos: local, life: 0.45, color: Theme.yellow))
        haptic(.light)
        sleepIn = max(sleepIn, 12)
        bitIn = max(bitIn, 2)
        dizzy += 0.5
        if dizzy >= 1 { enter(.dizzy) }
    }

    /// A finger holding it, `at` in world units from the home centre (nil until
    /// the drag reports where the finger is); called on every move.
    func hold(at local: CGPoint?) {
        if mode != .held {
            guard mode != .falling else { return }
            if sleeping { state.flash = 0.6; eyeScale = 1.3 }
            wakeUp()
            grabPending = true
            enter(.held)
        }
        guard let local else { return }
        if grabPending {
            grab = CGPoint(x: local.x - offset.x, y: local.y - offset.y + 0.12)   // it rises a little into the hand
            grabPending = false
        }
        finger = local
    }

    func release() {
        finger = nil
        guard mode == .held else { return }
        enter(.falling)
    }

    private func excitement(_ on: Bool) {
        guard on else { return }
        switch mode {
        case .asleep, .drowsy, .waking:
            enter(.startled)
        case .awake:
            if lift == 0 { jump(2.2); squashV = CGSize(width: -1.5, height: 2.5) }
            happy = 1; cheeks = 1
            state.spinKick += 5
            gazeTarget = CGPoint(x: -0.7, y: 0.6); gazeIn = 10
        default:
            break
        }
        sleepIn = max(sleepIn, 15)
    }

    // MARK: - physics, face, particles

    private func jump(_ v: Double) {
        guard lift == 0 else { return }
        vy = v
        lift = 0.001
    }

    private func physics(_ dt: Double) {
        if mode != .held && mode != .falling {
            if lift > 0 {
                vy -= 12 * dt
                lift += vy * dt
                if lift <= 0 { lift = 0; vy = 0; sinceLanded = 0 }
                else { sinceLanded += dt }
            } else {
                sinceLanded += dt
            }
            // a push springs back home
            let k = 90.0, d = 9.0
            offV.x += (-k * offset.x - d * offV.x) * dt
            offV.y += (-k * offset.y - d * offV.y) * dt
            offset.x += offV.x * dt
            offset.y += offV.y * dt
            sway = max(-1, min(1, offV.x / 3))
        } else {
            sinceLanded += dt
        }
        // the lean springs to upright; the shake dies out
        leanV += (-120 * lean - 11 * leanV) * dt
        lean += leanV * dt
        jitter -= jitter * min(1, 4.5 * dt)
        // the extra squash is a bouncy spring around its target
        let sk = 160.0, sd = 10.0
        squashV.width += (-sk * (state.squash.width - squashTarget.width) - sd * squashV.width) * dt
        squashV.height += (-sk * (state.squash.height - squashTarget.height) - sd * squashV.height) * dt
        state.squash.width += squashV.width * dt
        state.squash.height += squashV.height * dt
        // the slow things ease
        state.doze += (dozeTarget - state.doze) * min(1, 3.0 * dt)
        state.sink += (sinkTarget - state.sink) * min(1, 9 * dt)
        state.tintK += (tintTarget - state.tintK) * min(1, 2.5 * dt)
        happy = max(0, happy - dt * 1.4)
        cheeks = max(0, cheeks - dt * 1.2)
    }

    private func face(_ dt: Double) {
        if mode != .asleep && mode != .dizzy {
            blinkIn -= dt
            if blinkIn <= 0 {
                blinkClose = 0.11
                blinkIn = rng.unit() < 0.18 ? 0.28 : 2.2 + rng.unit() * 3.4   // sometimes a double blink
            }
        }
        blinkClose = max(0, blinkClose - dt)
        let target = blinkClose > 0 ? 1.0 : lidTarget
        lid += (target - lid) * min(1, (blinkClose > 0 ? 40 : lidSpeed) * dt)
        // saccades: a new spot to look at every second or three, a glance at the card when excited
        if mode == .awake, finger == nil, bit == nil {
            gazeIn -= dt
            if gazeIn <= 0 {
                gazeIn = 1.3 + rng.unit() * 2.6
                if excited { gazeTarget = CGPoint(x: -0.65 + rng.unit() * 0.3, y: 0.55 + rng.unit() * 0.3) }
                else if rng.unit() < 0.15 { gazeTarget = .zero }
                else { gazeTarget = CGPoint(x: (rng.unit() - 0.5) * 1.7, y: (rng.unit() - 0.5) * 0.9) }
            }
        }
        if mode != .dizzy {
            gaze.x += (gazeTarget.x - gaze.x) * min(1, 18 * dt)
            gaze.y += (gazeTarget.y - gaze.y) * min(1, 18 * dt)
        }
        mouthOpen += (mouthTarget - mouthOpen) * min(1, 12 * dt)
    }

    private func particles(_ dt: Double) {
        for i in glyphs.indices {
            glyphs[i].age += dt
            glyphs[i].pos.x += (glyphs[i].vel.x + 0.06 * sin(glyphs[i].age * 4 + glyphs[i].wobble)) * dt
            glyphs[i].pos.y += glyphs[i].vel.y * dt
        }
        glyphs.removeAll { $0.age >= $0.life }
        for i in sparks.indices {
            sparks[i].age += dt
            sparks[i].vel.y += 3.5 * dt
            sparks[i].pos.x += sparks[i].vel.x * dt
            sparks[i].pos.y += sparks[i].vel.y * dt
        }
        sparks.removeAll { $0.age >= $0.life }
        for i in rings.indices { rings[i].age += dt }
        rings.removeAll { $0.age >= $0.life }
    }

    private func smooth(_ x: Double) -> Double {
        let u = max(0, min(1, x))
        return u * u * (3 - 2 * u)
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        #if !targetEnvironment(macCatalyst)
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif
    }
}

/// The Home hero: the blob with its brain, tappable and holdable. Lays out at
/// `unit × 1.7` like `BlobHero`; the drawing gets a larger canvas underneath
/// so a jump, the "!" and the z's can leave the box.
struct HomeSplat: View {
    var unit: CGFloat = 62
    var running = true
    var excited = false
    @State private var brain = SplatBrain()

    private var box: CGFloat { unit * 1.7 }
    private var u: CGFloat { unit * 1.55 }
    /// The body's home centre in the box's coordinates.
    private var home: CGPoint { CGPoint(x: box / 2, y: box - unit * 0.12 - BlobArt.hover * u) }

    var body: some View {
        let canvas = unit * 4.6
        TimelineView(.animation(paused: !running)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                if brain.scripted == false { brain.excited = excited }
                brain.step(t)
                draw(&ctx, size: size, t: t)
            }
            .frame(width: canvas, height: canvas)
            .allowsHitTesting(false)
        }
        .frame(width: box, height: box)
        .contentShape(Rectangle())
        .onTapGesture { loc in brain.poke(at: world(loc)) }
        .gesture(pickUp)
        .accessibilityLabel("Splat")
        .accessibilityHint("Tap to poke, hold to pick up")
    }

    private func world(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - home.x) / u, y: (p.y - home.y) / u)
    }

    private var pickUp: some Gesture {
        LongPressGesture(minimumDuration: 0.28, maximumDistance: 14)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { v in
                if case .second(true, let drag) = v {
                    brain.hold(at: drag.map { world($0.location) })
                }
            }
            .onEnded { _ in brain.release() }
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let b = brain
        var p = SurferPose()
        p.t = t
        p.speed = 1
        p.lift = max(-0.12, b.lift - b.offset.y)
        p.sinceLanded = b.sinceLanded
        p.lean = b.lean + b.shake
        p.sway = b.sway
        // the box sits centred in the canvas; the ground line is where BlobHero puts it
        let origin = CGPoint(x: size.width / 2 + b.offset.x * u, y: size.height / 2 + box / 2 - unit * 0.12)
        let centre = BlobArt.draw(&ctx, origin: origin, unit: u, pose: p, state: b.state) { c in face(&c) }

        // the dizzy stars circle the head
        if b.mode == .dizzy {
            for i in 0..<3 {
                let a = t * 5.5 + Double(i) * 2.094
                let pt = CGPoint(x: centre.x + cos(a) * 0.34 * u, y: centre.y - 0.40 * u + sin(a) * 0.09 * u)
                star(&ctx, at: pt, r: 0.068 * u * (0.85 + 0.15 * sin(a)), spin: a, color: Theme.yellow, opacity: 1)
            }
        }
        for r in b.rings {
            let e = 1 - pow(1 - r.age / r.life, 2)
            let rad = (0.06 + 0.5 * e) * u
            let pt = CGPoint(x: centre.x + r.pos.x * u, y: centre.y + r.pos.y * u)
            ctx.stroke(Path(ellipseIn: CGRect(x: pt.x - rad, y: pt.y - rad, width: rad * 2, height: rad * 2)),
                       with: .color(r.color.opacity(1 - e)), style: StrokeStyle(lineWidth: 4 * (1 - e) + 0.5))
        }
        for s in b.sparks {
            let e = s.age / s.life
            let pt = CGPoint(x: centre.x + s.pos.x * u, y: centre.y + s.pos.y * u)
            star(&ctx, at: pt, r: 0.06 * u * (1 - 0.5 * e), spin: s.spin + s.age * 6, color: s.color, opacity: 1 - e * e)
        }
        for g in b.glyphs {
            let e = g.age / g.life
            var scale = 1.0, alpha = 1.0
            if g.pop {
                let k = min(1, g.age / 0.18)
                scale = 1.3 * sin(k * .pi / 2) * (k < 1 ? 1 : 1) - 0.3 * k * k
                alpha = e > 0.65 ? (1 - e) / 0.35 : 1
            } else {
                scale = 0.7 + 0.5 * e
                alpha = e < 0.15 ? e / 0.15 : (e > 0.6 ? (1 - e) / 0.4 : 1)
            }
            let pt = CGPoint(x: centre.x + g.pos.x * u, y: centre.y + g.pos.y * u)
            var gc = ctx
            gc.translateBy(x: pt.x, y: pt.y)
            gc.rotate(by: .radians(g.pop ? 0.18 : 0.12 * sin(g.age * 3 + g.wobble) - 0.25))
            gc.scaleBy(x: scale, y: scale)
            gc.opacity = alpha
            let font = Theme.black(g.size * u)
            // one layer, so the fade applies to the outlined glyph as a whole
            gc.drawLayer { l in
                let outline = l.resolve(Text(g.text).font(font).foregroundStyle(BlobArt.ink))
                for i in 0..<8 {
                    let a = Double(i) / 8 * 2 * .pi
                    l.draw(outline, at: CGPoint(x: cos(a) * 1.6, y: sin(a) * 1.6), anchor: .center)
                }
                l.draw(l.resolve(Text(g.text).font(font).foregroundStyle(g.color)), at: .zero, anchor: .center)
            }
        }
    }

    private func star(_ ctx: inout GraphicsContext, at pt: CGPoint, r: CGFloat, spin: Double, color: Color, opacity: Double) {
        var path = Path()
        for k in 0..<8 {
            let rad = k % 2 == 0 ? r : r * 0.42
            let a = spin + Double(k) * .pi / 4
            let q = CGPoint(x: pt.x + CGFloat(cos(a)) * rad, y: pt.y + CGFloat(sin(a)) * rad)   // explicit: Xcode 26.3 finds cos ambiguous here
            if k == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        path.closeSubpath()
        ctx.fill(path, with: .color(color.opacity(opacity)))
        ctx.stroke(path, with: .color(BlobArt.ink.opacity(opacity)), style: StrokeStyle(lineWidth: 0.8, lineJoin: .round))
    }

    /// The face, in world units centred on the core (y down): two kawaii eyes
    /// with lids and a gaze, cheeks when pleased, a mouth per mood.
    private func face(_ c: inout GraphicsContext) {
        let b = brain
        let ink = BlobArt.ink
        let ex = 0.072, ey = -0.032
        let er = 0.060 * b.eyeScale
        let pr = 0.038 * b.eyeScale * b.pupilScale
        for side in [-1.0, 1.0] {
            let cx = side * ex, cy = ey
            if b.happy > 0.5 {
                // a happy squint: an arch
                var arc = Path()
                arc.move(to: CGPoint(x: cx - er, y: cy + er * 0.35))
                arc.addQuadCurve(to: CGPoint(x: cx + er, y: cy + er * 0.35), control: CGPoint(x: cx, y: cy - er * 1.2))
                c.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: 0.026, lineCap: .round))
                continue
            }
            if b.lid > 0.94 {
                var line = Path()
                if b.sleeping {
                    // fast asleep: the lashes curve down
                    line.move(to: CGPoint(x: cx - er * 0.95, y: cy - er * 0.1))
                    line.addQuadCurve(to: CGPoint(x: cx + er * 0.95, y: cy - er * 0.1), control: CGPoint(x: cx, y: cy + er * 0.9))
                } else {
                    line.move(to: CGPoint(x: cx - er * 0.9, y: cy))
                    line.addLine(to: CGPoint(x: cx + er * 0.9, y: cy))
                }
                c.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: 0.024, lineCap: .round))
                continue
            }
            let eye = Path(ellipseIn: CGRect(x: cx - er, y: cy - er, width: 2 * er, height: 2 * er))
            c.fill(eye, with: .color(.white))
            let px = cx + b.gaze.x * (er - pr) * 0.95, py = cy + b.gaze.y * (er - pr) * 0.95
            c.fill(Path(ellipseIn: CGRect(x: px - pr, y: py - pr, width: 2 * pr, height: 2 * pr)), with: .color(ink))
            c.fill(Path(ellipseIn: CGRect(x: px + pr * 0.12, y: py - pr * 0.55, width: pr * 0.5, height: pr * 0.5)), with: .color(.white))
            if b.lid > 0.02 {
                // the lid comes down from the top, in the skin colour, with a lash line
                var lc = c
                lc.clip(to: eye)
                let h = 2 * er * b.lid
                lc.fill(Path(CGRect(x: cx - er - 0.01, y: cy - er - 0.01, width: 2 * er + 0.02, height: h + 0.01)), with: .color(BlobArt.skin(b.state)))
                var lash = Path()
                lash.move(to: CGPoint(x: cx - er, y: cy - er + h))
                lash.addLine(to: CGPoint(x: cx + er, y: cy - er + h))
                lc.stroke(lash, with: .color(ink), style: StrokeStyle(lineWidth: 0.016))
            }
        }
        if b.cheeks > 0.05 {
            for side in [-1.0, 1.0] {
                c.fill(Path(ellipseIn: CGRect(x: side * 0.092 - 0.026, y: 0.02, width: 0.052, height: 0.026)), with: .color(Theme.pink.opacity(0.75 * b.cheeks)))
            }
        }
        let my = 0.070
        switch b.mouth {
        case .smile:
            var m = Path()
            m.move(to: CGPoint(x: -0.036, y: my))
            m.addQuadCurve(to: CGPoint(x: 0.036, y: my), control: CGPoint(x: 0, y: my + 0.048))
            c.stroke(m, with: .color(ink), style: StrokeStyle(lineWidth: 0.02, lineCap: .round))
        case .grin:
            var m = Path()
            m.move(to: CGPoint(x: -0.048, y: my - 0.004))
            m.addQuadCurve(to: CGPoint(x: 0.048, y: my - 0.004), control: CGPoint(x: 0, y: my + 0.1))
            m.closeSubpath()
            c.fill(m, with: .color(ink))
            var tc = c
            tc.clip(to: m)
            tc.fill(Path(ellipseIn: CGRect(x: -0.008, y: my + 0.018, width: 0.04, height: 0.03)), with: .color(Theme.pink))
        case .o:
            let w = 0.03 + 0.024 * b.mouthOpen, h = 0.018 + 0.075 * b.mouthOpen
            c.fill(Path(ellipseIn: CGRect(x: -w / 2, y: my - 0.004, width: w, height: h)), with: .color(ink))
        case .flat:
            var m = Path()
            m.move(to: CGPoint(x: -0.03, y: my + 0.006))
            m.addLine(to: CGPoint(x: 0.03, y: my + 0.006))
            c.stroke(m, with: .color(ink), style: StrokeStyle(lineWidth: 0.02, lineCap: .round))
        case .wavy:
            var m = Path()
            m.move(to: CGPoint(x: -0.046, y: my + 0.004))
            m.addQuadCurve(to: CGPoint(x: -0.015, y: my + 0.004), control: CGPoint(x: -0.031, y: my - 0.018))
            m.addQuadCurve(to: CGPoint(x: 0.015, y: my + 0.004), control: CGPoint(x: 0, y: my + 0.026))
            m.addQuadCurve(to: CGPoint(x: 0.046, y: my + 0.004), control: CGPoint(x: 0.031, y: my - 0.018))
            c.stroke(m, with: .color(ink), style: StrokeStyle(lineWidth: 0.018, lineCap: .round))
        }
    }
}
