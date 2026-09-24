import Foundation
import CoreGraphics

/// Token Surfers rules. Three lanes; the track is laid in authored chunks
/// (like Subway Surfers' prefab pieces) so there is always a way through:
/// box trains kill you from the front and bump you from the side, ramp
/// trains carry you up onto the roofs, low barriers are jumped, overhead
/// gates are rolled under. A crash ends the run (score, leaderboard, run it
/// back); a side bump only costs the streak.
///
/// The agent feeds it: streamed tokens become coin trails, tool calls become
/// terminal-liveried trains, bugs found by run_app crawl onto the track
/// (stomp them), a finished build rains confetti.
///
/// Plain class (not @Observable): the view pulls state every frame.
final class SurfEngine {
    enum Kind { case coin, train, rampTrain, barrier, gate, bug }

    struct Entity {
        var kind: Kind
        var lane: Int
        var z: Double            // near end, ahead of the player (world units)
        var length: Double = 0.4
        var label: String = ""
        var color: Int = 0
        var y: Double = 0.55     // coins float; roof coins sit above trains
        var speed: Double = 0    // oncoming trains move toward the player
        var stopAt: Double? = nil // …until here, so they never roll into the piece before them
        var dead = false
        var phase: Double = 0
        var token = false        // coin born from a streamed token
        var tool = false         // train born from a tool call (terminal livery)
    }

    struct Particle { var x, y, vx, vy, life, hue, spin: Double }

    static let laneWidth = 1.25
    static let trainH = 2.0
    static let trainW = 0.5        // half width
    static let rampLen = 3.4
    static let carLen = 9.0
    static let viewDepth = 96.0

    // Player
    private(set) var lane = 0
    /// The in-game Splat's springs (animation only, see BlobArt).
    let blob = BlobState()
    private var prevLane = 0
    private(set) var x = 0.0
    private(set) var y = 0.0
    private(set) var vy = 0.0
    private(set) var ground = 0.0        // surface under the player this frame
    private(set) var rolling = 0.0
    private(set) var stumble = 0.0
    private(set) var invulnerable = 0.0
    private(set) var runPhase = 0.0
    private(set) var landedAt = -10.0
    private(set) var over = false
    private(set) var deathAt = 0.0
    var onRoof: Bool { ground > 0.5 && y <= ground + 0.01 }
    var airborne: Bool { y > ground + 0.02 }

    // World
    private(set) var entities: [Entity] = []
    private(set) var distance = 0.0
    private(set) var speed = 11.0
    private var chunkCursor = 30.0
    private var lastChunk = -1
    private var rng = SeededRandom(seed: UInt64(Date().timeIntervalSince1970 * 1000))
    private(set) var confetti: [Particle] = []
    private(set) var time = 0.0
    private(set) var runs = 0

    // Score
    private(set) var score = 0
    private(set) var coins = 0
    private(set) var streak = 0
    private(set) var bumps = 0
    private(set) var stomps = 0
    private var coinScore = 0
    var multiplier: Int { 1 + min(4, streak / 25) }

    // Agent feed
    private var tokenBank = 0.0
    private var tokenFlow = 0.0
    private var pendingTrains: [String] = []
    private var pendingBugs = 0
    private(set) var lastEvent: (text: String, at: Double)?

    var paused = false
    /// The bot reads the track ahead and plays: the build pane demos itself
    /// with it until the player takes over (TS_BOT=1 in the simulator).
    var autopilot = false
    /// Set once a human has taken the controls (build pane attract mode).
    var takenOver = false
    private(set) var botLog: [String] = []
    var onCrash: (() -> Void)?            // a bump
    var onGameOver: ((Int) -> Void)?
    var onSound: ((SurfSound) -> Void)?
    var onSpeed: ((Double) -> Void)?      // 0..1, for the music tempo

    // MARK: input

    private var canAct: Bool { !over && stumble <= 0 }

    func left() {
        guard canAct, lane > -1 else { return }
        prevLane = lane; lane -= 1
        onSound?(.swipe)
    }
    func right() {
        guard canAct, lane < 1 else { return }
        prevLane = lane; lane += 1
        onSound?(.swipe)
    }
    func jump() {
        guard canAct, !airborne else { return }
        vy = 8.2
        rolling = 0
        onSound?(.jump)
    }
    func roll() {
        guard canAct else { return }
        if airborne { vy = -18 }
        rolling = 0.62
        onSound?(.roll)
    }

    /// New run. The agent's pending trains, bugs and token bank survive.
    func restart() {
        entities.removeAll()
        lane = 0; prevLane = 0; x = 0; y = 0; vy = 0; ground = 0
        rolling = 0; stumble = 0; invulnerable = 0; runPhase = 0
        over = false
        distance = 0; speed = 11; chunkCursor = 30; lastChunk = -1
        score = 0; coins = 0; streak = 0; bumps = 0; stomps = 0; coinScore = 0
        confetti.removeAll()
        lastEvent = nil
        runs += 1
    }

    // MARK: agent feed

    func feedTokens(_ n: Double) {
        tokenBank += n
        tokenFlow += n
    }

    func toolTrain(_ name: String) { pendingTrains.append(name) }

    func bugs(_ n: Int) {
        pendingBugs += min(n, 8)
        if n > 0 { lastEvent = ("\(n) BUG\(n == 1 ? "" : "S") ON THE TRACK", time) }
    }

    func toast(_ text: String) { lastEvent = (text, time) }

    func celebrate() {
        for _ in 0..<110 {
            confetti.append(Particle(x: rng.unit(), y: -0.05 - rng.unit() * 0.3,
                                     vx: (rng.unit() - 0.5) * 0.25, vy: 0.25 + rng.unit() * 0.35,
                                     life: 2.6 + rng.unit(), hue: rng.unit(), spin: rng.unit() * 6))
        }
        if !over {
            streak += 25
            lastEvent = ("SHIPPED  x\(multiplier)", time)
        }
        onSound?(.celebrate)
    }

    // MARK: tick

    func step(_ rawDt: Double) {
        guard !paused else { return }
        let dt = min(rawDt, 1.0 / 20)
        time += dt

        // Speed: ramps with distance, surges while tokens are streaming, dies with you.
        tokenFlow *= exp(-dt * 1.5)
        let base = min(20, 11 + distance / 900)
        let target = over ? 0 : base + min(4, tokenFlow / 60)
        speed += (target - speed) * min(1, dt * (over ? 6 : 2))
        let v = stumble > 0 ? speed * 0.4 : speed
        if !over {
            distance += v * dt
            runPhase += dt * v * 0.95
            score = Int(distance * 1.5) + coinScore
            onSpeed?(min(1, max(0, (speed - 11) / 13)))
        }

        // Lateral motion
        let targetX = Double(lane) * Self.laneWidth
        x += (targetX - x) * min(1, dt * 15)

        // Move the world
        for i in entities.indices {
            entities[i].z -= (v + entities[i].speed) * dt
            entities[i].phase += dt
            if let stop = entities[i].stopAt {
                entities[i].stopAt = stop - v * dt
                if entities[i].z <= stop - v * dt { entities[i].speed = 0; entities[i].stopAt = nil }
            }
        }
        chunkCursor -= v * dt
        entities.removeAll { $0.z + $0.length < -4 || $0.dead }

        if !over {
            let prevGround = ground
            ground = surfaceHeight()
            // Vertical motion: gravity when above the surface, otherwise sit on it
            // (a ramp pushes you up; a roof that ends drops you).
            if y > ground + 0.001 || vy > 0 {
                vy -= 27 * dt
                y += vy * dt
                if y <= ground {
                    y = ground; vy = 0
                    landedAt = time
                    onSound?(ground > 0.5 ? .roofLand : .land)
                }
            } else {
                y = ground
                if ground > prevGround + 0.001, ground >= Self.trainH - 0.001, prevGround < Self.trainH - 0.001 {
                    onSound?(.roofLand)
                }
            }
            rolling = max(0, rolling - dt)
            stumble = max(0, stumble - dt)
            invulnerable = max(0, invulnerable - dt)

            lay()
            if autopilot { autopilotStep() }
            collide()
        }
        stepConfetti(dt)
    }

    // MARK: autopilot (debug)

    /// What would hurt at ground level in a lane, nearest first, within `range`.
    private func hazards(_ lane: Int, range: Double) -> [Entity] {
        entities.filter { e in
            !e.dead && e.lane == lane && e.z > -0.75 && e.z < range && e.kind != .coin
        }.sorted { $0.z < $1.z }
    }

    private func laneClear(_ lane: Int, _ range: Double) -> Bool {
        !entities.contains { e in
            !e.dead && e.lane == lane && e.kind != .coin && e.kind != .bug && e.z < range && e.z + e.length > -0.6
        }
    }

    private var botLast = 0.0

    /// How far a lane can be run before something you can't jump or roll:
    /// a box train's front, a ramp's side, or a barrier/gate too close to
    /// react to. -1 = a train body already beside us (switching bumps).
    private func laneDanger(_ l: Int) -> Double {
        var d = 99.0
        for e in entities where !e.dead && e.lane == l && e.kind != .coin {
            switch e.kind {
            case .train, .rampTrain:
                if e.z <= 0.4 && e.z + e.length > -0.6 {
                    if l == lane { continue }                 // we're on or at it already
                    if e.kind == .rampTrain && y >= Self.trainH - 0.5 { continue }
                    return -1
                }
                if e.kind == .train, e.z > 0.4 { d = min(d, e.z) }
            case .barrier, .gate:
                if e.z > -0.4 && e.z < 2.0 { d = min(d, e.z) }
            case .bug:
                if e.z > -0.4 && e.z < 1.5 { d = min(d, e.z) }
            case .coin:
                break
            }
        }
        return d
    }

    private func autopilotStep() {
        guard time - botLast > 0.05 else { return }
        botLast = time
        guard stumble <= 0 else { return }
        let under = trainUnderfoot()

        // Standing on a roof: watch for the drop and what comes after it.
        if let (_, t) = under, y >= Self.trainH - 0.5 {
            let end = t.z + t.length
            if end < 4 {
                let after = entities.filter { !$0.dead && $0.lane == lane && $0.kind != .coin && $0.z >= end - 0.5 && $0.z < end + 9 }
                if !after.isEmpty {
                    let options = [lane - 1, lane + 1].filter { (-1...1).contains($0) }
                    if let l = options.max(by: { laneDanger($0) < laneDanger($1) }), laneDanger(l) > 8 {
                        l < lane ? left() : right(); return
                    }
                }
            }
            return
        }

        // A box train coming at us: move to the lane that runs the longest.
        let here = laneDanger(lane)
        if let train = entities.first(where: { !$0.dead && $0.lane == lane && $0.kind == .train && $0.z > 0.4 && $0.z < 9 }) {
            let options = [lane - 1, lane + 1].filter { (-1...1).contains($0) }
            if let l = options.max(by: { laneDanger($0) < laneDanger($1) }), laneDanger(l) > here {
                l < lane ? left() : right(); return
            } else if train.z < 1.5 {
                botLog.append(String(format: "t=%.1f no way out in lane %d at %.0f m", time, lane, distance))
            }
        }

        // What's next in this lane, and the reaction for it.
        let ahead = hazards(lane, range: 12)
        if let h = ahead.first {
            switch h.kind {
            case .barrier:
                if h.z < 3.6, !airborne { jump() }
            case .gate:
                if h.z < 3.0 { roll() }
            case .bug:
                // Sidestep when a lane runs clear (a bite stuns you); otherwise stomp it.
                if h.z < 4.5 {
                    let options = [lane - 1, lane + 1].filter { (-1...1).contains($0) }
                    if let l = options.first(where: { laneDanger($0) > 12 && laneClear($0, 10) }) {
                        l < lane ? left() : right()
                    } else if h.z < 2.6, !airborne {
                        jump()
                    }
                }
            case .rampTrain, .train, .coin:
                break
            }
            return
        }

        // Nothing ahead: drift toward coins.
        let coinsHere = entities.contains { !$0.dead && $0.kind == .coin && $0.lane == lane && $0.z > 0 && $0.z < 12 }
        if !coinsHere {
            for l in [lane - 1, lane + 1] where (-1...1).contains(l) && laneClear(l, 16) {
                if entities.contains(where: { !$0.dead && $0.kind == .coin && $0.lane == l && $0.z > 1 && $0.z < 10 && $0.y < 1 }) {
                    l < lane ? left() : right(); return
                }
            }
        }
    }

    // MARK: surfaces

    /// The train under the player (same lane, spanning z = 0), if any.
    private func trainUnderfoot() -> (index: Int, entity: Entity)? {
        for i in entities.indices {
            let e = entities[i]
            guard !e.dead, e.lane == lane, e.kind == .train || e.kind == .rampTrain else { continue }
            if e.z <= 0.35, e.z + e.length >= -0.35 { return (i, e) }
        }
        return nil
    }

    /// Height of what the player is standing on: 0, a ramp's slope, or a roof.
    private func surfaceHeight() -> Double {
        guard let (_, t) = trainUnderfoot() else { return 0 }
        let into = -t.z                       // how far past the near end we are
        if t.kind == .rampTrain, into < Self.rampLen {
            let slope = Self.trainH * max(0, into) / Self.rampLen
            // Came in from the side under the slope: that's a wall, not a floor.
            return y >= slope - 0.55 ? slope : 0
        }
        // A box roof is a floor only if we are already up there.
        return y >= Self.trainH - 0.5 ? Self.trainH : 0
    }

    // MARK: laying the track

    private func lay() {
        // Tool trains and token coins ride in with the course.
        while chunkCursor < Self.viewDepth {
            let len: Double
            if !pendingTrains.isEmpty {
                len = layToolTrain(at: chunkCursor, label: pendingTrains.removeFirst())
            } else {
                len = layChunk(at: chunkCursor)
            }
            let gap = max(6, 11 - distance / 600)
            chunkCursor += len + gap
        }
        layTokenCoins()
        layBugs()
    }

    private func occupied(_ lane: Int, _ z0: Double, _ z1: Double) -> Bool {
        entities.contains { e in
            !e.dead && e.lane == lane && e.kind != .coin && e.kind != .bug && e.z < z1 && e.z + e.length > z0
        }
    }

    private func lanes() -> [Int] { [-1, 0, 1].shuffled(using: &rng) }

    private func train(_ lane: Int, _ z: Double, _ len: Double, ramp: Bool = false, speed: Double = 0, stopAt: Double? = nil, tool: String? = nil) {
        entities.append(Entity(kind: ramp ? .rampTrain : .train, lane: lane, z: z, length: len,
                               label: tool ?? "", color: rng.int(4), y: 0, speed: speed, stopAt: stopAt, tool: tool != nil))
    }

    private func barrier(_ lane: Int, _ z: Double) {
        entities.append(Entity(kind: .barrier, lane: lane, z: z, length: 0.3, y: 0))
    }

    private func gate(_ lane: Int, _ z: Double) {
        entities.append(Entity(kind: .gate, lane: lane, z: z, length: 0.3, y: 0))
    }

    private func coins(_ lane: Int, _ z: Double, _ n: Int, y: Double = 0.55, spacing: Double = 1.5, token: Bool = false) {
        for k in 0..<n {
            entities.append(Entity(kind: .coin, lane: lane, z: z + Double(k) * spacing, y: y, token: token))
        }
    }

    /// A jump arc of coins over a low barrier at z.
    private func coinArc(_ lane: Int, over z: Double) {
        let n = 5
        for k in 0..<n {
            let u = Double(k) / Double(n - 1)
            entities.append(Entity(kind: .coin, lane: lane, z: z - 2.6 + u * 5.2, y: 0.55 + sin(u * .pi) * 1.15))
        }
    }

    private func roofCoins(_ lane: Int, _ z: Double, _ len: Double) {
        let n = Int(len / 1.6)
        coins(lane, z + Self.rampLen + 1.0, max(0, n - 3), y: Self.trainH + 0.55, spacing: 1.6)
    }

    /// One authored piece of track. Returns its length. Every piece leaves a
    /// way through: a free lane, a ramp, or something you can jump or roll.
    private func layChunk(at z: Double) -> Double {
        let hard = min(1, distance / 2500)
        var choices: [Int] = [0, 1, 3, 4, 5, 7]
        if hard > 0.2 { choices += [2, 6] }
        if hard > 0.5 { choices += [1, 2, 6] }
        var pick = choices[rng.int(choices.count)]
        if pick == lastChunk { pick = choices[rng.int(choices.count)] }
        lastChunk = pick
        let l = lanes()

        switch pick {
        case 0: // gauntlet: two parked trains, coins down the free lane
            train(l[0], z, 12 + rng.unit() * 8)
            train(l[1], z + rng.unit() * 6, 12 + rng.unit() * 8)
            coins(l[2], z + 1, 10)
            return 26

        case 1: // ramp ride: run up one train; the free lane has a gate
            let len = 20.0
            train(l[0], z, len, ramp: true)
            roofCoins(l[0], z, len)
            train(l[1], z + 6, 12)
            gate(l[2], z + 9)
            coins(l[2], z + 11, 5)
            return len + 6

        case 2: // roof hop: two ramp trains staggered so you cross roof to roof
            train(l[0], z, 16, ramp: true)
            roofCoins(l[0], z, 16)
            train(l[1], z + 13, 18, ramp: true)
            coins(l[1], z + 13 + Self.rampLen + 2, 8, y: Self.trainH + 0.55, spacing: 1.6)
            train(l[2], z + 5, 22)
            return 36

        case 3: // hurdles: low barriers walking across the lanes, arcs of coins over them
            let order = [l[0], l[1], l[2], l[0]]
            for (k, lane) in order.enumerated() {
                let bz = z + 2 + Double(k) * 8
                barrier(lane, bz)
                coinArc(lane, over: bz)
            }
            return 30

        case 4: // gates: overhead signs to roll under, low coins beneath
            gate(l[0], z + 3); gate(l[1], z + 3)
            coins(l[0], z + 1, 3, y: 0.4, spacing: 1.2)
            gate(l[1], z + 13); gate(l[2], z + 13)
            coins(l[2], z + 11, 3, y: 0.4, spacing: 1.2)
            coins(l[2], z, 4)
            return 22

        case 5: // coin field: a zigzag, nothing to hit
            var lane = l[0]
            var zz = z
            for _ in 0..<4 {
                coins(lane, zz, 4)
                zz += 6.5
                lane = max(-1, min(1, lane + (rng.unit() < 0.5 ? -1 : 1)))
            }
            return 28

        case 6: // oncoming: a train rolling toward you, headlights on (it parks at the piece's start)
            train(l[0], z + 26, 14, speed: 4.5 + hard * 2, stopAt: z + 1)
            train(l[1], z, 10)
            coins(l[2], z + 2, 9)
            coins(l[0], z + 4, 5)
            return 30

        default: // breather
            coins(l[0], z + 1, 7)
            return 14
        }
    }

    /// A tool call: one terminal-liveried train, the other lanes stay open.
    private func layToolTrain(at z: Double, label: String) -> Double {
        let l = lanes()
        let ramp = rng.unit() < 0.4
        train(l[0], z, 14, ramp: ramp, tool: label)
        if ramp { roofCoins(l[0], z, 14) }
        coins(l[1], z + 1, 6)
        return 16
    }

    /// Token coins: one coin per ~7 streamed tokens, in a clear lane far
    /// ahead, or along a ramp train's roof.
    private func layTokenCoins() {
        guard tokenBank >= 7 else { return }
        let n = min(Int(tokenBank / 7), 10)
        let far = Self.viewDepth - 8
        let span = Double(n) * 1.6
        for lane in lanes() {
            if !occupied(lane, far - 2, far + span + 2) {
                coins(lane, far, n, spacing: 1.6, token: true)
                tokenBank -= Double(n) * 7
                return
            }
            if entities.contains(where: { $0.kind == .rampTrain && $0.lane == lane && !$0.dead
                    && $0.z + Self.rampLen + 1 <= far && $0.z + $0.length >= far + span }) {
                coins(lane, far, n, y: Self.trainH + 0.55, spacing: 1.6, token: true)
                tokenBank -= Double(n) * 7
                return
            }
        }
    }

    private func layBugs() {
        guard pendingBugs > 0 else { return }
        let l = lanes()
        for lane in l where !occupied(lane, 34, 46) {
            entities.append(Entity(kind: .bug, lane: lane, z: 40, length: 0.5, y: 0, speed: -1.5))
            pendingBugs -= 1
            return
        }
    }

    // MARK: collisions

    private func collide() {
        let h = Self.trainH
        for i in entities.indices where !entities[i].dead {
            let e = entities[i]
            guard e.lane == lane else { continue }
            let overlaps = e.z < 0.45 && e.z + e.length > -0.45
            guard overlaps else { continue }

            switch e.kind {
            case .coin:
                if abs(y + 0.6 - e.y) < 1.0, abs(x - Double(lane) * Self.laneWidth) < 0.7 {
                    entities[i].dead = true
                    coins += 1
                    streak += 1
                    coinScore += 10 * multiplier
                    if streak % 25 == 0 { lastEvent = ("x\(multiplier)", time); onSound?(.streak) }
                    onSound?(.coin)
                }

            case .bug:
                if vy < 0 && y > 0.05 {
                    entities[i].dead = true
                    stomps += 1
                    coinScore += 250 * multiplier
                    vy = 6.5
                    lastEvent = ("SQUASHED  +\(250 * multiplier)", time)
                    onSound?(.stomp)
                } else if y < 0.45 && invulnerable <= 0 {
                    bump(back: false)
                    lastEvent = ("BITTEN", time)
                }

            case .barrier:
                if y < 0.8 { die() }

            case .gate:
                if rolling <= 0 && y < 1.5 { die() }

            case .train, .rampTrain:
                guard y < h - 0.5 else { continue }          // on the roof
                let into = -e.z
                if e.kind == .rampTrain, into < Self.rampLen {
                    let slope = h * max(0, into) / Self.rampLen
                    if y < slope - 0.55 { bump(back: true) }  // side of the slope
                    continue
                }
                if e.z > -0.75 { die() }                      // the front hit us
                else { bump(back: true) }                     // we walked into its side
            }
        }
    }

    /// A side collision: bounce back to the lane we came from, lose the streak.
    private func bump(back: Bool) {
        guard invulnerable <= 0 else { return }
        if back {
            let from = prevLane == lane ? (lane == 0 ? (x < 0 ? -1 : 1) : 0) : prevLane
            if occupied(from, -1.5, 1.5) { die(); return }
            lane = from
            prevLane = from
        }
        bumps += 1
        streak = 0
        stumble = 0.5
        invulnerable = 1.2
        speed *= 0.65
        onSound?(.bump)
        onCrash?()
    }

    private func die() {
        guard !over else { return }
        if autopilot {
            let near = entities.filter { !$0.dead && $0.z > -3 && $0.z < 6 && $0.kind != .coin }
                .map { "\($0.kind)@\($0.lane) z\(String(format: "%.1f", $0.z)) len\(Int($0.length))" }
            botLog.append(String(format: "DEATH t=%.1f lane %d y %.2f stumble %.2f vy %.1f at %.0f m: ", time, lane, y, stumble, vy, distance) + near.joined(separator: ", "))
            print("[bot] " + botLog.last!)
        }
        over = true
        deathAt = time
        streak = 0
        onSound?(.crash)
        onGameOver?(score)
    }

    private func stepConfetti(_ dt: Double) {
        guard !confetti.isEmpty else { return }
        for i in confetti.indices {
            confetti[i].x += confetti[i].vx * dt
            confetti[i].y += confetti[i].vy * dt
            confetti[i].vy += 0.12 * dt
            confetti[i].life -= dt
            confetti[i].spin += dt * 5
        }
        confetti.removeAll { $0.life <= 0 || $0.y > 1.2 }
    }
}

enum SurfSound { case coin, jump, land, roofLand, roll, swipe, bump, crash, stomp, streak, celebrate, tick, gameOver }
