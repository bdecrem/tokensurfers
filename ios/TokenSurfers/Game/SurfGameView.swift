import SwiftUI

/// The playable Token Surfers pane: canvas, HUD, swipes, taps and arrow keys,
/// the game-over card with the world rank, and (solo) a start screen + pause.
struct SurfGameView: View {
    let engine: SurfEngine
    var running: Bool
    var compact = false
    var mode = "build"                  // "build" (under a build) | "solo"
    var autoplay = false                // solo: skip the start screen
    var onClose: (() -> Void)? = nil

    private var solo: Bool { mode == "solo" }

    @State private var clock = FrameClock()
    @State private var swipeFired = false
    @State private var oofAt: Date?
    @State private var overCard = false
    @State private var armed = false
    @State private var attract = false        // build pane: the bot plays until you touch it
    @State private var paused = false
    @State private var showBoard = false
    @State private var askHandle = false
    @State private var submitted: SubmitResult?
    @State private var submitting = false
    @State private var board = Leaderboard.shared
    @State private var width: CGFloat = 390
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focused: Bool

    private var active: Bool { running && !paused && (solo ? armed : true) && scenePhase == .active }

    var body: some View {
        TimelineView(.animation(paused: !active)) { tl in
            let now = tl.date
            ZStack {
                Canvas { ctx, size in
                    let dt = clock.tick(now)
                    engine.step(dt)
                    SurfRenderer(e: engine, size: size).draw(&ctx)
                }
                hud(now)
            }
        }
        .contentShape(Rectangle())
        .gesture(swipe)
        .simultaneousGesture(SpatialTapGesture().onEnded { tap($0.location) })
        .overlay(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } })
        .overlay { overlays }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .space, .return, .escape, "a", "d", "w", "s", "p", "r"]) { press in
            if solo, !armed { armed = true; focused = true; return .handled }
            if attract { takeOver(); return .handled }
            if engine.over {
                if press.key == .space || press.key == .return || press.key == "r" { restart(); return .handled }
                return .ignored
            }
            switch press.key {
            case .leftArrow, "a": engine.left()
            case .rightArrow, "d": engine.right()
            case .upArrow, .space, "w": engine.jump()
            case .downArrow, "s": engine.roll()
            case "p", .escape: if solo { paused.toggle() }
            default: return .ignored
            }
            return .handled
        }
        .onAppear {
            engine.onSound = { SurfAudio.shared.play($0) }
            engine.onCrash = { oofAt = .now }
            engine.onSpeed = { SurfAudio.shared.pace = $0 }
            engine.onGameOver = { score in gameOver(score) }
            if autoplay { armed = true }
            if !solo, !engine.takenOver {
                attract = true
                engine.autopilot = true
            }
            engine.paused = !active
            SurfAudio.shared.start()
            if solo { Task { await board.refresh() } }
        }
        .onDisappear { SurfAudio.shared.musicTarget = 0 }
        .task(id: attract) {
            // attract mode never shows a game over: the bot just runs it back
            guard attract else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if engine.over, engine.time - engine.deathAt > 1.2 { engine.restart() }
            }
        }
        .onChange(of: active, initial: true) { _, a in
            engine.paused = !a
            clock.reset()
            SurfAudio.shared.musicTarget = a ? (engine.over ? 0.3 : 1) : 0
        }
        .sheet(isPresented: $showBoard) { LeaderboardView() }
        .sheet(isPresented: $askHandle) { HandleSheet { submit() } }
        .accessibilityLabel("Token Surfers game. Swipe to change lanes, jump or roll.")
    }

    // MARK: input

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { v in
                guard !swipeFired else { return }
                let dx = v.translation.width, dy = v.translation.height
                guard max(abs(dx), abs(dy)) > 22 else { return }
                swipeFired = true
                focused = true
                if solo, !armed { armed = true; return }
                if attract { takeOver(); return }
                guard !engine.over, !paused else { return }
                if abs(dx) > abs(dy) { dx < 0 ? engine.left() : engine.right() }
                else { dy < 0 ? engine.jump() : engine.roll() }
            }
            .onEnded { _ in swipeFired = false }
    }

    /// Taps: left third / right third change lanes, the middle jumps.
    private func tap(_ p: CGPoint) {
        focused = true
        if solo, !armed { armed = true; return }
        if attract { takeOver(); return }
        guard !engine.over, !paused else { return }
        if p.x < width / 3 { engine.left() }
        else if p.x > width * 2 / 3 { engine.right() }
        else { engine.jump() }
    }

    /// The player takes the controls from the bot: a fresh run that counts.
    private func takeOver() {
        attract = false
        engine.autopilot = false
        engine.takenOver = true
        engine.restart()
        engine.toast("YOU'RE UP")
        SurfAudio.shared.play(.streak)
    }

    // MARK: game over

    private func gameOver(_ score: Int) {
        // Attract mode (the bot playing) never shows the card or posts a score.
        guard !engine.autopilot else { return }
        submitted = nil
        board.noteRun(score: score)
        SurfAudio.shared.musicTarget = 0.3
        Task {
            try? await Task.sleep(for: .seconds(0.7))
            SurfAudio.shared.play(.gameOver)
            try? await Task.sleep(for: .seconds(0.4))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { overCard = true }
        }
        if board.hasHandle { submit() }
    }

    private func submit() {
        guard !submitting else { return }
        submitting = true
        let score = engine.score, coins = engine.coins, distance = Int(engine.distance)
        Task {
            submitted = await board.submit(score: score, coins: coins, distance: distance, mode: mode)
            submitting = false
        }
    }

    private func restart() {
        overCard = false
        submitted = nil
        engine.restart()
        clock.reset()
        SurfAudio.shared.musicTarget = 1
        SurfAudio.shared.play(.tick)
    }

    // MARK: overlays

    @ViewBuilder private func hud(_ now: Date) -> some View {
        let s = compact ? 0.75 : 1.0
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: -4) {
                    StrokedText(text: "x\(engine.multiplier)", font: Theme.anton(34 * s), color: engine.multiplier > 1 ? Theme.yellow : .white, stroke: 2.5)
                    StrokedText(text: "TOKEN SURFERS", font: Theme.anton(13 * s), stroke: 1.5)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    StrokedText(text: String(format: "%07d", engine.score), font: Theme.anton(30 * s), stroke: 2.5)
                        .monospacedDigit()
                    HStack(spacing: 4) {
                        Circle().fill(Theme.yellow).overlay(Circle().strokeBorder(Color(hex: 0xB9801E), lineWidth: 2))
                            .frame(width: 16 * s, height: 16 * s)
                        StrokedText(text: "\(engine.coins)", font: Theme.anton(17 * s), color: Theme.yellow, stroke: 1.5)
                    }
                    if board.localBest > 0 {
                        StrokedText(text: "best \(board.localBest.formatted())", font: Theme.anton(11 * s), stroke: 1.2)
                            .opacity(0.9)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, solo ? 10 : 8)
            .padding(.leading, solo ? 42 : 0)
            .padding(.trailing, solo ? 42 : 0)
            Spacer()
        }
        .allowsHitTesting(false)

        if let oof = oofAt, now.timeIntervalSince(oof) < 0.9, !engine.over {
            StrokedText(text: "OOF", font: Theme.black(34 * s), color: .white, stroke: 3)
                .scaleEffect(1 + max(0, 0.3 - now.timeIntervalSince(oof)))
                .allowsHitTesting(false)
        } else if let ev = engine.lastEvent, engine.time - ev.at < 1.6, !engine.over {
            StrokedText(text: ev.text, font: Theme.black(24 * s), color: Theme.yellow, stroke: 2.5)
                .offset(y: -30)
                .allowsHitTesting(false)
        }
        if engine.over, engine.time - engine.deathAt < 1.4, !overCard {
            StrokedText(text: "BRUH 💀", font: Theme.black(44 * s), color: .white, stroke: 3.5)
                .scaleEffect(1 + max(0, 0.4 - (engine.time - engine.deathAt)) * 2)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var overlays: some View {
        ZStack {
            if solo {
                VStack {
                    HStack {
                        if let onClose {
                            circleButton("xmark", label: "Close") { onClose() }
                        }
                        Spacer()
                        if armed, !engine.over {
                            circleButton(paused ? "play.fill" : "pause.fill", label: paused ? "Resume" : "Pause") { paused.toggle() }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    Spacer()
                }
            }
            if solo, !armed { intro }
            if attract { attractHint }
            if paused, !engine.over { pauseCard }
            if overCard { gameOverCard }
        }
    }

    private var intro: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 14) {
                BlobHero(unit: compact ? 36 : 54)
                VStack(spacing: -8) {
                    StrokedText(text: "TOKEN", font: Theme.anton(compact ? 30 : 44), stroke: 3)
                    StrokedText(text: "SURFERS", font: Theme.anton(compact ? 36 : 54), color: Theme.yellow, stroke: 3.5)
                }
                Text("swipe ← → for lanes · ↑ jump · ↓ roll\nrun up the striped ramps. jump on the bugs.")
                    .font(Theme.rounded(13, .bold)).multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: Theme.ink.opacity(0.7), radius: 0, y: 1.5)
                TimelineView(.periodic(from: .now, by: 0.6)) { tl in
                    StrokedText(text: "TAP TO SURF", font: Theme.black(22), color: Theme.yellow, stroke: 2.5)
                        .opacity(Int(tl.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0 ? 1 : 0.5)
                }
                if let you = board.you {
                    Text("you're #\(you.rank) of \(board.surfers) · best \(you.best.formatted())")
                        .font(Theme.rounded(12.5, .heavy)).foregroundStyle(Theme.yellow)
                        .shadow(color: Theme.ink.opacity(0.7), radius: 0, y: 1.5)
                }
            }
            .padding(.top, 20)
        }
        .allowsHitTesting(false)
    }

    private var attractHint: some View {
        VStack {
            Spacer()
            TimelineView(.periodic(from: .now, by: 0.7)) { tl in
                Text("swipe to take over")
                    .font(Theme.black(compact ? 12 : 14)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .opacity(Int(tl.date.timeIntervalSinceReferenceDate / 0.7) % 2 == 0 ? 1 : 0.6)
            }
            .padding(.bottom, compact ? 8 : 14)
        }
        .allowsHitTesting(false)
    }

    private var pauseCard: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 14) {
                StrokedText(text: "PAUSED", font: Theme.anton(40), stroke: 3)
                ChunkyButton(title: "RESUME") { paused = false }
                if let onClose {
                    ChunkyButton(title: "QUIT", fill: .white, textColor: Theme.ink) { onClose() }
                }
            }
            .frame(width: 220)
        }
    }

    private var gameOverCard: some View {
        let s = compact ? 0.78 : 1.0
        return ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 10 * s) {
                HStack(spacing: 10) {
                    BlobHero(unit: 22 * s, mood: .dead, running: false)
                    VStack(alignment: .leading, spacing: -6) {
                        StrokedText(text: "GAME OVER", font: Theme.anton(26 * s), stroke: 2.5)
                        Text(engine.score >= board.localBest && engine.score > 0 && engine.runs >= 0 && submitted?.best == engine.score
                             ? "NEW BEST 🔥" : "you had a good run")
                            .font(Theme.black(11 * s)).foregroundStyle(Theme.yellow)
                            .shadow(color: Theme.ink, radius: 0, y: 1)
                    }
                }
                HStack(spacing: 18 * s) {
                    stat("SCORE", engine.score.formatted(), s)
                    stat("COINS", "\(engine.coins)", s)
                    stat("BEST", board.localBest.formatted(), s)
                }
                rankLine(s)
                HStack(spacing: 10) {
                    ChunkyButton(title: "RUN IT BACK", height: 46 * s) { restart() }
                    Button { showBoard = true } label: {
                        Text("🏆").font(.system(size: 22 * s))
                            .frame(width: 46 * s, height: 46 * s)
                            .background(Circle().fill(.white).overlay(Circle().strokeBorder(Theme.ink, lineWidth: 2.5)))
                            .background(Circle().fill(Theme.ink).offset(y: 4))
                    }
                    .buttonStyle(SquishStyle())
                    .accessibilityLabel("Leaderboard")
                }
            }
            .padding(16 * s)
            .frame(width: min(width - 24, 340 * s + 40))
            .paperCard(radius: 22)
        }
    }

    @ViewBuilder private func rankLine(_ s: Double) -> some View {
        if let r = submitted {
            Text(r.rank == 1 ? "#1 IN THE WORLD 👑" : "#\(r.rank) in the world")
                .font(Theme.black(15 * s)).foregroundStyle(Theme.ink)
        } else if submitting {
            Text("posting…").font(Theme.black(13 * s)).foregroundStyle(Theme.ink2)
        } else if !board.hasHandle {
            Button { askHandle = true } label: {
                Text("claim a spot on the board →")
                    .font(Theme.black(13 * s)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Theme.yellow))
                    .overlay(Capsule().strokeBorder(Theme.ink, lineWidth: 1.5))
            }
            .buttonStyle(SquishStyle())
        } else if let e = board.error {
            Text("offline: \(e)").font(Theme.rounded(11 * s, .bold)).foregroundStyle(Theme.ink2).lineLimit(1)
        }
    }

    private func stat(_ label: String, _ value: String, _ s: Double) -> some View {
        VStack(spacing: -2) {
            Text(value).font(Theme.anton(24 * s)).foregroundStyle(Theme.ink).monospacedDigit()
            Text(label).font(Theme.black(9 * s)).foregroundStyle(Theme.ink2)
        }
    }

    private func circleButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Theme.ink)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.white.opacity(0.94)))
        }
        .buttonStyle(SquishStyle())
        .accessibilityLabel(label)
    }
}

/// Solo mode from Home: the game full screen.
struct GameScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var engine = SurfEngine()

    var body: some View {
        ZStack {
            Color(hex: 0xEE7F52).ignoresSafeArea()
            SurfGameView(engine: engine, running: true, mode: "solo", autoplay: ProcessInfo.processInfo.environment["TS_BOT"] != nil) { dismiss() }
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .statusBarHidden(true)
        .onAppear {
            // TS_BOT=1: the debug autopilot plays; TS_BOT=restart: and restarts after every death.
            if let bot = ProcessInfo.processInfo.environment["TS_BOT"] {
                engine.autopilot = true
                if bot == "die" {
                    Task {
                        try? await Task.sleep(for: .seconds(14))
                        engine.autopilot = false
                    }
                }
                if bot == "restart" {
                    Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(1))
                            if engine.over, engine.time - engine.deathAt > 2 { engine.restart() }
                        }
                    }
                }
            }
        }
    }
}

/// Frame delta bookkeeping outside SwiftUI state (mutated from the Canvas).
final class FrameClock {
    private var last: Date?
    func tick(_ now: Date) -> Double {
        defer { last = now }
        guard let last else { return 0 }
        return max(0, now.timeIntervalSince(last))
    }
    func reset() { last = nil }
}
