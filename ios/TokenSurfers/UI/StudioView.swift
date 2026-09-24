import SwiftUI

/// The split screen from the video, made usable: the stage (your app, or the
/// code being written) on top, Token Surfers underneath, the caption on the
/// seam, a composer at the bottom. Wide windows go side by side.
struct StudioView: View {
    @Bindable var studio: Studio
    var initialPrompt: String?
    var onBack: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""
    @State private var split: CGFloat = 0.5          // stage share while the game is open
    @State private var gameOpen = true
    @State private var userSized = false
    @State private var fullscreenApp = false
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false
    @State private var showDone = false
    @State private var dragStart: CGFloat?
    @State private var account = SurfAccount.shared
    @State private var showAccount = false
    @State private var publishing = false
    @State private var publishNote: String?
    @State private var publishedURL: URL?
    @State private var voice = VoiceInput()
    @State private var holding = false
    @State private var cancelArmed = false
    @State private var showLog = false
    @State private var stopArmed = false
    @AppStorage("muted") private var muted = false
    @AppStorage("narrator") private var narrator = true
    @AppStorage("music") private var music = true
    @FocusState private var composerFocused: Bool

    var body: some View {
        GeometryReader { g in
            let wide = g.size.width > 720 && g.size.width > g.size.height * 1.05
            Group {
                if wide { wideLayout(g.size) } else { tallLayout(g.size) }
            }
            .background(alignment: .top) {
                (studio.stageTab == .app && (!studio.html.isEmpty || studio.siteURL != nil) ? Color.white : Theme.navy).ignoresSafeArea()
            }
        }
        .ignoresSafeArea(.container, edges: wideEdges)
        .statusBarHidden(false)
        .onAppear {
            SurfAudio.shared.start()
            voice.warmUp()
            gameOpen = (studio.html.isEmpty && studio.siteURL == nil) || studio.building
            if let p = initialPrompt, !p.isEmpty, studio.html.isEmpty, studio.siteURL == nil, !studio.building { studio.send(p) }
            studio.attach()   // a build still running on the mini
            if ProcessInfo.processInfo.environment["TS_PUBLISH"] != nil {
                Task { try? await Task.sleep(for: .seconds(2)); publish() }
            }
            simulatorHooks()
        }
        .onChange(of: studio.building) { _, b in
            if b {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { gameOpen = true; if !userSized { split = 0.5 } }
            } else {
                // stopped or failed with notes still waiting: hand them back, nothing is lost
                let left = studio.takeQueue()
                if !left.isEmpty { draft = ([draft] + left).filter { !$0.isEmpty }.joined(separator: ". ") }
            }
        }
        .onChange(of: studio.phase) { _, p in
            guard p == .done else { return }
            showDone = true
            // give the finale a moment, then hand the screen back to the app
            Task {
                try? await Task.sleep(for: .seconds(4.5))
                showDone = false
                if !studio.building && !userSized {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { gameOpen = false }
                }
            }
        }
        .fullScreenCover(isPresented: $fullscreenApp) { fullscreen }
        .sheet(isPresented: $showLog) { BuildLog(items: studio.feed) }
        .alert(voice.problem ?? "", isPresented: Binding(get: { voice.problem != nil }, set: { if !$0 { voice.problem = nil } })) {
            Button("OK", role: .cancel) { voice.problem = nil }
        }
        .sheet(isPresented: $showAccount) { AccountSheet { publish() } }
        .alert(publishNote ?? "", isPresented: Binding(get: { publishNote != nil }, set: { if !$0 { publishNote = nil } })) {
            if let url = publishedURL {
                ShareLink(item: url) { Text("Share the link") }
            }
            Button("OK", role: .cancel) { publishNote = nil }
        }
        .alert("Rename app", isPresented: $renaming) {
            TextField("name", text: $newTitle)
            Button("Save") { if !newTitle.isEmpty { studio.rename(newTitle) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(studio.project.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete app", role: .destructive) {
                studio.store.delete(studio.project.id)
                onBack()
            }
        }
    }

    private var wideEdges: Edge.Set { [] }

    private var gameRunning: Bool { gameOpen && scenePhase == .active && !fullscreenApp }

    // MARK: tall (iPhone, narrow windows)

    private func tallLayout(_ size: CGSize) -> some View {
        let composerH = composerHeight
        let avail = size.height - composerH
        let stageH = gameOpen ? max(160, avail * split) : avail
        let gameH = max(0, avail - stageH)   // the keyboard can shrink avail below the stage minimum
        return VStack(spacing: 0) {
            stage
                .frame(height: stageH)
                .clipped()
                .overlay(alignment: .top) { topBar }
            if gameOpen {
                game(compact: gameH < 260)
                    .frame(height: gameH)
                    .clipped()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            composer
                .frame(height: composerH)
        }
        .overlay(alignment: .top) {
            // open: the caption straddles the seam and the handle sits on the game;
            // closed: the whole thing rides the stage's bottom edge, handle just above the composer
            seam(width: size.width)
                .offset(y: gameOpen ? stageH - 34 : stageH - 76)
                .gesture(resize(total: avail))
        }
    }

    // MARK: wide (iPad landscape, Mac windows)

    private func wideLayout(_ size: CGSize) -> some View {
        let side = min(460, max(360, size.width * 0.38))
        return HStack(spacing: 0) {
            stage
                .overlay(alignment: .top) { topBar }
                .clipShape(RoundedRectangle(cornerRadius: 0))
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    if gameOpen {
                        game(compact: false)
                    } else {
                        ZStack {
                            Sunburst(spin: false)
                            PaperGrain(opacity: 0.1)
                            VStack(spacing: 14) {
                                BlobHero(unit: 60)
                                Button { withAnimation { gameOpen = true } } label: {
                                    Label("Surf while you wait", systemImage: "figure.surfing")
                                        .font(Theme.black(15)).foregroundStyle(Theme.ink)
                                        .padding(.horizontal, 18).padding(.vertical, 12)
                                        .background(Capsule().fill(.white))
                                }
                                .buttonStyle(SquishStyle())
                            }
                        }
                    }
                    captionOverlay
                        .padding(.top, 70)
                }
                composer.frame(height: composerHeight)
            }
            .frame(width: side)
        }
    }

    // MARK: pieces

    @ViewBuilder private var stage: some View {
        ZStack {
            switch studio.stageTab {
            case .app:
                if let site = studio.siteURL {
                    SiteWebView(url: site, version: studio.previewVersion)
                        .padding(.top, 52)
                        .background(Color.white)
                } else if studio.html.isEmpty {
                    if studio.building { CodeView(code: studio.codeForDisplay, streaming: true) } else { EmptyStage() }
                } else {
                    PreviewWebView(html: studio.html, version: studio.previewVersion, projectID: studio.project.id)
                        .padding(.top, 52)
                        .background(Color.white)
                }
            case .code:
                CodeView(code: studio.codeForDisplay, streaming: studio.building,
                         isPatch: studio.isPatch && studio.phase == .editing,
                         patchOld: studio.patchOld, patchNew: studio.patchNew)
            }
            if let c = studio.cutaway {
                CutawayView(cutaway: c, bugs: studio.lastBugs)
                    .id(c)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if studio.building || showDone, studio.cutaway == nil, !studio.feed.isEmpty {
                LiveFeed(items: studio.feed)
                    .padding(.leading, 10)
                    .padding(.bottom, gameOpen ? 44 : 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: studio.cutaway)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: studio.feed)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            circleButton("chevron.left", label: "Back") { onBack() }
            Button { newTitle = studio.project.title; renaming = true } label: {
                HStack(spacing: 6) {
                    Text(studio.project.emoji).font(.system(size: 18))
                    Text(studio.project.title)
                        .font(Theme.black(15))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(Capsule().fill(.white.opacity(0.94)))
                .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.12)))
            }
            .buttonStyle(SquishStyle())
            Spacer(minLength: 4)
            tabs
            layoutButton
            menu
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    /// The way back from a full-screen stage, always in the bar: shows or hides the game pane.
    private var layoutButton: some View {
        Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                gameOpen.toggle()
                if gameOpen { split = 0.5; userSized = false }
            }
        } label: {
            Image(systemName: gameOpen ? "rectangle.split.1x2.fill" : "rectangle.split.1x2")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white.opacity(0.94)))
        }
        .buttonStyle(SquishStyle())
        .accessibilityLabel(gameOpen ? "Hide the game" : "Show the game")
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach([Studio.StageTab.app, .code], id: \.self) { t in
                Button {
                    withAnimation(.snappy) { studio.stageTab = t; studio.stagePinned = studio.building }
                } label: {
                    Text(t == .app ? "APP" : "CODE")
                        .font(Theme.black(12))
                        .foregroundStyle(studio.stageTab == t ? .white : Theme.ink)
                        .frame(width: 52, height: 30)
                        .background(Capsule().fill(studio.stageTab == t ? Theme.ink : .clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(.white.opacity(0.94)))
    }

    private var menu: some View {
        Menu {
            Button { fullscreenApp = true } label: { Label("Open app fullscreen", systemImage: "arrow.up.left.and.arrow.down.right") }
                .disabled(studio.html.isEmpty && studio.siteURL == nil)
            if let site = studio.siteURL {
                ShareLink(item: site) { Label("Share the app", systemImage: "link") }
            }
            ShareLink(item: studio.store.exportURL(for: studio.project)) { Label("Share HTML", systemImage: "square.and.arrow.up") }
                .disabled(studio.html.isEmpty)
            Divider()
            Button { publish() } label: {
                Label(studio.project.remoteSlug == nil ? "Publish to the gallery" : "Update in the gallery", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled((studio.html.isEmpty && studio.siteURL == nil) || studio.building || publishing)
            if let slug = studio.project.remoteSlug, let url = URL(string: "\(backendURL().absoluteString)/surf/a/\(slug)") {
                ShareLink(item: url) { Label(studio.siteURL == nil ? "Share the link" : "Share its gallery page", systemImage: "square.grid.2x2") }
                Button(role: .destructive) { unpublish() } label: { Label("Unpublish", systemImage: "eye.slash") }
            }
            Divider()
            Toggle(isOn: Binding(get: { !muted }, set: { muted = !$0 })) { Label("Sound", systemImage: "speaker.wave.2") }
            Toggle(isOn: $music) { Label("Music", systemImage: "music.note") }
            Toggle(isOn: $narrator) { Label("Narrator voice", systemImage: "waveform") }
            Button { showLog = true } label: { Label("What Splat did", systemImage: "list.bullet.rectangle") }
                .disabled(studio.feed.isEmpty)
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete app", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white.opacity(0.94)))
        }
        .accessibilityLabel("More")
    }

    private func circleButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white.opacity(0.94)))
        }
        .buttonStyle(SquishStyle())
        .accessibilityLabel(label)
    }

    private func game(compact: Bool) -> some View {
        SurfGameView(engine: studio.game, running: gameRunning, compact: compact, mode: "build")
            .overlay(alignment: .bottomLeading) {
                SubtitleBox(text: studio.subtitle)
                    .padding(10)
                    .opacity(studio.building || showDone ? 1 : 0)
            }
            .overlay(alignment: .topTrailing) {
                if !studio.building {
                    Button { withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { gameOpen = false } } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(.black.opacity(0.35)))
                    }
                    .padding(.top, 66).padding(.trailing, 10)
                    .accessibilityLabel("Hide game")
                }
            }
    }

    /// The caption rides the seam; it doubles as the resize handle.
    private func seam(width: CGFloat) -> some View {
        VStack(spacing: 4) {
            captionOverlay
                .frame(height: 60)
            // the grab handle: drag down to give the stage the screen, drag up to bring the game back
            Capsule().fill(gameOpen ? .white.opacity(0.5) : Theme.ink.opacity(0.28)).frame(width: 44, height: 5)
                .shadow(color: (gameOpen ? Color.black : .white).opacity(0.3), radius: 1, y: 1)
        }
        .frame(width: width, height: 72)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var captionOverlay: some View {
        if (studio.building || showDone || studio.phase != .idle && studio.phase != .done) && !studio.caption.isEmpty {
            CaptionBand(caption: studio.caption, id: studio.captionID, size: 32, filler: studio.captionIsFiller)
                .frame(maxWidth: .infinity)
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private func resize(total: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if !gameOpen {
                    if v.translation.height < -28 {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { gameOpen = true; split = 0.5 }
                        userSized = false
                    }
                    return
                }
                if dragStart == nil { dragStart = split }
                split = min(0.8, max(0.22, (dragStart ?? split) + v.translation.height / total))
                userSized = true
            }
            .onEnded { v in
                dragStart = nil
                if split > 0.78, v.predictedEndTranslation.height > 60 {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { gameOpen = false; split = 0.5 }
                    userSized = false
                }
            }
    }

    // MARK: composer

    private static let followUps = ["make it prettier ✨", "add sound effects 🔊", "more chaos 🌀", "add a high score 🏆", "dark mode 🌚"]

    private var chipsVisible: Bool { !studio.building && !studio.html.isEmpty && !composerFocused && draft.isEmpty && !voice.listening }

    private var composerHeight: CGFloat { chipsVisible || studio.building ? 108 : 70 }

    /// Always open, even mid-build: what you send while Splat works waits for
    /// his next step (or goes right now with ⚡). The mic is hold-to-talk.
    private var composer: some View {
        VStack(spacing: 8) {
            if studio.building {
                buildStrip
            } else if chipsVisible {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if !gameOpen {
                            chip("🏄 surf") { withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { gameOpen = true } }
                        }
                        ForEach(Self.followUps, id: \.self) { s in chip(s) { studio.send(s) } }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: 32)
            }
            HStack(spacing: 10) {
                if voice.listening || holding {
                    listeningField
                } else {
                    TextField(placeholder, text: $draft, axis: .vertical)
                        .font(Theme.rounded(16, .semibold))
                        .foregroundStyle(Theme.ink)   // the field is white whatever the system scheme is
                        .tint(Theme.splat)
                        .lineLimit(1...3)
                        .focused($composerFocused)
                        .submitLabel(.send)
                        .onSubmit(send)
                        // a vertical-axis field turns Return into a newline; here Return sends
                        .onChange(of: draft) { _, v in
                            guard v.hasSuffix("\n") else { return }
                            draft = String(v.dropLast())
                            send()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 23, style: .continuous).fill(.white))
                        .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).strokeBorder(Theme.ink, lineWidth: 2))
                }
                if case .failed = studio.phase, draft.isEmpty, !holding {
                    roundButton("arrow.clockwise", fill: Theme.yellow, fg: Theme.ink, label: "Retry") { studio.retry() }
                }
                if draft.trimmingCharacters(in: .whitespaces).isEmpty || holding {
                    micButton
                } else {
                    roundButton("arrow.up", fill: Theme.splat, fg: .white, label: studio.building ? "Tell Splat" : "Send", action: send)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 10)
        .frame(maxHeight: .infinity)
        .background(Theme.orange.overlay(PaperGrain(opacity: 0.08)))
    }

    private var placeholder: String {
        if studio.building { return "tell splat… he'll catch it next step" }
        return studio.html.isEmpty ? "what are we building?" : "change something…"
    }

    /// Splat's status, your queued notes, and Stop.
    private var buildStrip: some View {
        HStack(spacing: 6) {
            statusPill
                .padding(.leading, 12)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(studio.queue) { n in queuedChip(n).id(n.id) }
                    }
                }
                .onChange(of: studio.queue.count) { _, _ in
                    if let last = studio.queue.last { withAnimation { proxy.scrollTo(last.id, anchor: .trailing) } }
                }
            }
            // two taps: it sits next to the note chips, and one stray tap used to end the build
            Button {
                if stopArmed {
                    stopArmed = false
                    studio.stop()
                } else {
                    stopArmed = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { try? await Task.sleep(for: .seconds(2.5)); stopArmed = false }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .black))
                    Text(stopArmed ? "sure?" : "stop").font(Theme.black(13))
                }
                .foregroundStyle(stopArmed ? Theme.ink : .white)
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(stopArmed ? Theme.yellow : Theme.red))
                .overlay(Capsule().strokeBorder(Theme.ink, lineWidth: 1.5))
                .fixedSize()
            }
            .buttonStyle(SquishStyle())
            .accessibilityLabel(stopArmed ? "Tap again to stop" : "Stop")
            .padding(.trailing, 12)
        }
        .frame(height: 32)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            BlobHero(unit: 13, energy: splatEnergy)
                .frame(height: 30)
            // with notes waiting, room goes to them: just Splat and the count
            if studio.queue.isEmpty {
                Text(phaseLabel).font(Theme.black(13)).foregroundStyle(Theme.ink)
                Text("· \(studio.outputTokens.formatted()) tok")
                    .font(Theme.rounded(11.5, .bold)).foregroundStyle(Theme.ink2)
                    .monospacedDigit()
            } else {
                Text(studio.outputTokens.formatted())
                    .font(Theme.rounded(11.5, .bold)).foregroundStyle(Theme.ink2)
                    .monospacedDigit()
            }
        }
        .padding(.leading, 4).padding(.trailing, 10)
        .fixedSize()
        .frame(height: 32)
        .background(Capsule().fill(.white))
        .overlay(Capsule().strokeBorder(Theme.ink, lineWidth: 1.5))
    }

    private var phaseLabel: String {
        switch studio.phase {
        case .thinking: return "cooking…"
        case .writing: return "writing the app"
        case .editing: return "patching"
        case .reading: return "reading the code"
        case .running: return "test-driving it"
        default: return "…"
        }
    }

    /// How hard the little Splat dances: flat out while writing, idling while he thinks.
    private var splatEnergy: Double {
        switch studio.phase {
        case .writing: return 1
        case .editing: return 0.85
        case .running: return 0.7
        case .reading: return 0.45
        default: return 0.3
        }
    }

    private func queuedChip(_ n: Studio.Note) -> some View {
        HStack(spacing: 6) {
            Text(n.voice ? "🎙️" : "⏳").font(.system(size: 12))
            Text(n.text).font(Theme.rounded(13, .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading)
            Button { studio.deliverNow() } label: {
                Text("⚡ now").font(Theme.black(11)).foregroundStyle(.white)
                    .padding(.horizontal, 7).frame(height: 22)
                    .background(Capsule().fill(Theme.ink))
            }
            .buttonStyle(SquishStyle())
            .accessibilityLabel("Send to Splat now")
            if !studio.remote {   // the mini already has it; there is no taking it back
                Button { studio.unqueue(n.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .black)).foregroundStyle(Theme.ink)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Take it back")
            }
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: 32)
        .background(Capsule().fill(Theme.yellow))
        .overlay(Capsule().strokeBorder(Theme.ink, lineWidth: 1.5))
        .transition(.scale.combined(with: .opacity))
    }

    private var listeningField: some View {
        HStack(spacing: 10) {
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                HStack(spacing: 3) {
                    ForEach(0..<4) { i in
                        Capsule().fill(cancelArmed ? Theme.ink2 : Theme.red)
                            .frame(width: 4, height: 8 + 12 * abs(sin(t * 7 + Double(i) * 0.9)))
                    }
                }
                .frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(!voice.listening ? "opening the mic…" : voice.transcript.isEmpty ? "listening…" : voice.transcript)
                    .font(Theme.rounded(15, .semibold)).foregroundStyle(voice.listening ? Theme.ink : Theme.ink2)
                    .lineLimit(2).truncationMode(.head)
                Text(cancelArmed ? "let go to cancel" : "let go to send · slide up to cancel")
                    .font(Theme.rounded(11, .bold)).foregroundStyle(Theme.ink2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 23, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).strokeBorder(cancelArmed ? Theme.ink2 : Theme.red, lineWidth: 2.5))
    }

    /// Hold to talk. Idle: the words start a build. Building: they queue for Splat's next step.
    private var micButton: some View {
        let live = voice.listening || holding
        return Image(systemName: live ? "waveform" : "mic.fill")
            .font(.system(size: 18, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(Circle().fill(live ? Theme.red : Theme.ink))
            .overlay(Circle().strokeBorder(Theme.ink, lineWidth: 2))
            .scaleEffect(live ? 1.18 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: live)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !holding { beginTalking() }
                        cancelArmed = v.translation.height < -60
                    }
                    .onEnded { _ in endTalking(send: !cancelArmed) }
            )
            .accessibilityLabel("Hold to talk to Splat")
    }

    private func beginTalking() {
        holding = true
        cancelArmed = false
        composerFocused = false
        studio.setListening(true)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { await voice.start() }
    }

    private func endTalking(send: Bool) {
        holding = false
        Task {
            let text = await voice.stop()
            studio.setListening(false)
            cancelArmed = false
            if send, !text.isEmpty { studio.send(text, voice: true) }
        }
    }

    // MARK: simulator hooks

    /// TS_INJECT="note" (+ TS_INJECT_AT=seconds, TS_INJECT_NOW=1) sends a note
    /// mid-build; TS_HEAR=/path/to/audio.aiff transcribes a file through the
    /// voice path and sends it the same way.
    private func simulatorHooks() {
        let env = ProcessInfo.processInfo.environment
        if let d = env["TS_DRAFT"], !d.isEmpty { draft = d }
        let at = Double(env["TS_INJECT_AT"] ?? "") ?? 12
        if let note = env["TS_INJECT"], !note.isEmpty {
            Task {
                try? await Task.sleep(for: .seconds(at))
                studio.send(note)
                if env["TS_INJECT_NOW"] != nil {
                    try? await Task.sleep(for: .seconds(1.5))
                    studio.deliverNow()
                }
            }
        }
        if let path = env["TS_HEAR"], !path.isEmpty {
            Task {
                try? await Task.sleep(for: .seconds(at))
                let text = await voice.transcribe(file: URL(fileURLWithPath: path))
                print("[voice] heard: \(text)")
                if !text.isEmpty { studio.send(text, voice: true) }
            }
        }
    }

    private func chip(_ s: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(Theme.rounded(13.5, .bold)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(.white.opacity(0.92)))
                .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.8), lineWidth: 1.5))
        }
        .buttonStyle(SquishStyle())
    }

    private func roundButton(_ icon: String, fill: Color, fg: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .black)).foregroundStyle(fg)
                .frame(width: 46, height: 46)
                .background(Circle().fill(fill))
                .overlay(Circle().strokeBorder(Theme.ink, lineWidth: 2))
        }
        .buttonStyle(SquishStyle())
        .accessibilityLabel(label)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        composerFocused = false   // the keyboard would otherwise squash the stage and the game
        studio.send(text)
    }

    // MARK: publishing

    private func publish() {
        guard account.signedIn else { showAccount = true; return }
        publishing = true
        Task {
            do {
                let app = try await account.publish(project: studio.project, html: studio.html, siteURL: studio.siteURL?.absoluteString)
                studio.setRemoteSlug(app.slug)
                // the app itself is the link to hand out; the gallery page is where it's listed
                let link = studio.siteURL?.absoluteString ?? app.url
                publishedURL = URL(string: link)
                publishNote = studio.siteURL == nil ? "It's live at \(app.url)" : "It's live at \(link) and listed in the gallery."
                SurfAudio.shared.play(.celebrate)
            } catch {
                publishNote = "Couldn't publish: \(error.localizedDescription)"
            }
            publishing = false
        }
    }

    private func unpublish() {
        guard let slug = studio.project.remoteSlug else { return }
        Task {
            do {
                try await account.unpublish(slug: slug)
                studio.setRemoteSlug(nil)
                publishedURL = nil
                publishNote = "Taken down."
            } catch {
                publishNote = "Couldn't unpublish: \(error.localizedDescription)"
            }
        }
    }

    // MARK: fullscreen app

    private var fullscreen: some View {
        ZStack(alignment: .topTrailing) {
            Color.white.ignoresSafeArea()
            if let site = studio.siteURL {
                SiteWebView(url: site, version: studio.previewVersion)
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                PreviewWebView(html: studio.html, version: studio.previewVersion, projectID: studio.project.id)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
            Button { fullscreenApp = false } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .black)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(Circle().fill(.black.opacity(0.5)))
            }
            .padding(10)
            .accessibilityLabel("Close")
        }
    }
}
