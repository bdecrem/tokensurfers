import SwiftUI

/// Home: the AITA-card-on-a-sunburst from the video's opening shot, turned
/// into a prompt box, plus a shelf of the apps you've made.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    var open: (UUID, String?) -> Void

    @State private var draft = ""
    @State private var renaming: Project?
    @State private var newTitle = ""
    @State private var deleting: Project?
    @State private var showGame = false
    @State private var showBoard = false
    @State private var showGallery = false
    @State private var showAccount = false
    @State private var board = Leaderboard.shared
    @State private var account = SurfAccount.shared
    @AppStorage("muted") private var muted = false
    @AppStorage("music") private var music = true
    @AppStorage("narrator") private var narrator = true
    @FocusState private var focused: Bool

    private static let ideas = [
        "a pomodoro timer that screams at me",
        "flappy bird but it's a splat",
        "a to-do list that judges me 💅",
        "tip calculator for 3am decisions",
        "a snake game with rizz",
        "a mood tracker with cursed emojis",
    ]

    var body: some View {
        ZStack {
            Sunburst(spin: false)
                .ignoresSafeArea()
            PaperGrain(opacity: 0.09).ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 22) {
                        header
                        promptCard
                        galleryCard
                        shelf.id("shelf")
                        surfCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .task {
                    // TS_SCROLL=apps: the shelf in a screenshot without a finger
                    if ProcessInfo.processInfo.environment["TS_SCROLL"] == "apps" {
                        try? await Task.sleep(for: .seconds(1.2))
                        withAnimation { proxy.scrollTo("shelf", anchor: .top) }
                    }
                }
            }
        }
        .task {
            if ProcessInfo.processInfo.environment["TS_SOLO"] != nil { showGame = true }
            if ProcessInfo.processInfo.environment["TS_BOARD"] != nil { showBoard = true }
            if ProcessInfo.processInfo.environment["TS_GALLERY"] != nil {
                try? await Task.sleep(for: .seconds(1.5))
                showGallery = true
            }
            if ProcessInfo.processInfo.environment["TS_ACCOUNT"] != nil { showAccount = true }
            await board.refresh()
        }
        .fullScreenCover(isPresented: $showGame) { GameScreen().onDisappear { Task { await board.refresh(force: true) } } }
        .sheet(isPresented: $showBoard) { LeaderboardView() }
        .sheet(isPresented: $showAccount) { AccountSheet() }
        .fullScreenCover(isPresented: $showGallery) { GalleryView { id in open(id, nil) }.environment(model) }
        .alert("Rename app", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("name", text: $newTitle)
            Button("Save") {
                if var p = renaming, !newTitle.isEmpty { p.title = newTitle; model.store.update(p) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete \(deleting?.title ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete app", role: .destructive) {
                if let p = deleting { model.store.delete(p.id); model.studios[p.id] = nil }
                deleting = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: -8) {
                StrokedText(text: "TOKEN", font: Theme.anton(50), stroke: 3.5)
                StrokedText(text: "SURFERS", font: Theme.anton(50), color: Theme.yellow, stroke: 3.5)
                Text("vibe code while you surf")
                    .font(Theme.black(13))
                    .foregroundStyle(.white)
                    .shadow(color: Theme.ink.opacity(0.6), radius: 0, x: 0, y: 2)
                    .padding(.top, 12)
            }
            Spacer()
            BlobHero(unit: 58)
        }
        .padding(.top, 14)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                if account.signedIn {
                    Menu {
                        Button { showGallery = true } label: { Label("The gallery", systemImage: "square.grid.2x2") }
                        Button(role: .destructive) { account.signOut() } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
                    } label: {
                        Text("@\(account.handle)").font(Theme.black(12)).foregroundStyle(Theme.ink).lineLimit(1)
                            .padding(.horizontal, 10).frame(height: 34).background(Capsule().fill(.white.opacity(0.9)))
                    }
                } else {
                    Button { showAccount = true } label: {
                        Text("sign in").font(Theme.black(12)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 10).frame(height: 34).background(Capsule().fill(.white.opacity(0.9)))
                    }
                    .buttonStyle(SquishStyle())
                }
                Menu {
                    Toggle(isOn: Binding(get: { !muted }, set: { muted = !$0 })) { Label("Sound", systemImage: "speaker.wave.2") }
                    Toggle(isOn: $music) { Label("Music", systemImage: "music.note") }
                    Toggle(isOn: $narrator) { Label("Narrator voice", systemImage: "waveform") }
                    Divider()
                    // new apps only; an app keeps the engine that built it
                    Toggle(isOn: Binding(get: { Studio.engine == .remote }, set: { Studio.engine = $0 ? .remote : .local })) {
                        Label("Claude Code on the mini", systemImage: "desktopcomputer")
                    }
                } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 14, weight: .black)).foregroundStyle(Theme.ink)
                        .frame(width: 34, height: 34).background(Circle().fill(.white.opacity(0.9)))
                }
            }
            .offset(y: -6)
        }
        .overlay(alignment: .bottomTrailing) {
            if model.store.totalTokens > 0 {
                Text("🪙 \(model.store.totalTokens.formatted()) tokens surfed")
                    .font(Theme.rounded(12, .heavy))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(Theme.yellow))
                    .overlay(Capsule().strokeBorder(Theme.ink, lineWidth: 1.5))
                    .offset(y: 16)
            }
        }
    }

    // The reddit-post card from the video, as the prompt box.
    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SplatMascot(size: 26, face: false, animate: false)
                VStack(alignment: .leading, spacing: 0) {
                    Text("r/VibeCoding").font(Theme.black(13)).foregroundStyle(Theme.ink)
                    Text("u/you · just now").font(Theme.rounded(11, .medium)).foregroundStyle(Theme.ink2)
                }
                Spacer()
                Text("NEED APP")
                    .font(Theme.black(10)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.splat))
            }
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("AITA for wanting an app that…")
                        .font(Theme.heavy(22))
                        .foregroundStyle(Theme.ink.opacity(0.28))
                        .allowsHitTesting(false)
                }
                TextField("", text: $draft, axis: .vertical)
                    .font(Theme.heavy(22))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2...6)
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit(start)
            }
            // idea chips
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 7) {
                ForEach(Self.ideas, id: \.self) { idea in
                    Button { draft = idea } label: {
                        Text(idea).font(Theme.rounded(12.5, .bold)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Capsule().fill(Theme.cream))
                            .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.18), lineWidth: 1))
                    }
                    .buttonStyle(SquishStyle())
                }
              }
              .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
            HStack(spacing: 14) {
                Label("\(model.store.projects.count)", systemImage: "square.stack.fill")
                Label(model.store.totalTokens > 0 ? "\(model.store.totalTokens.formatted()) tokens" : "no builds yet", systemImage: "circle.hexagongrid.fill")
                Spacer()
            }
            .font(Theme.rounded(12, .bold))
            .foregroundStyle(Theme.ink2)
            ChunkyButton(title: "SURF IT 🏄", fill: draft.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.ink2.opacity(0.5) : Theme.splat, action: start)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16)
        .paperCard(radius: 22)
    }

    // Everyone's creations: play, upvote, remix.
    private var galleryCard: some View {
        Button { showGallery = true } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.navy)
                    Starfield().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).opacity(0.7)
                    Text("🖼️").font(.system(size: 26))
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    StrokedText(text: "THE GALLERY", font: Theme.anton(22), color: Theme.yellow, stroke: 2.5)
                    Text("what everyone made · play · upvote · remix")
                        .font(Theme.rounded(12, .heavy)).foregroundStyle(Theme.ink2)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .black)).foregroundStyle(Theme.ink)
            }
            .padding(12)
            .paperCard(radius: 20)
        }
        .buttonStyle(SquishStyle())
    }

    // Play the runner on its own; the world's top three and your rank.
    private var surfCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    StrokedText(text: "TOKEN SURFERS", font: Theme.anton(24), color: Theme.yellow, stroke: 2.5)
                    Text(surfLine).font(Theme.rounded(12.5, .heavy)).foregroundStyle(Theme.ink2)
                }
                Spacer()
                BlobHero(unit: 22, mood: .cool)
            }
            ChunkyButton(title: "SURF NOW 🏄", fill: Theme.splat) { showGame = true }
            if !board.top.isEmpty {
                VStack(spacing: 6) {
                    ForEach(board.top.prefix(3)) { row in
                        HStack(spacing: 8) {
                            Text(["🥇", "🥈", "🥉"][row.rank - 1]).font(.system(size: 16))
                            Text(row.handle).font(Theme.black(13)).foregroundStyle(Theme.ink).lineLimit(1)
                            if row.you { Text("you").font(Theme.black(9)).foregroundStyle(Theme.splat) }
                            Spacer()
                            Text(row.score.formatted()).font(Theme.anton(16)).foregroundStyle(Theme.ink).monospacedDigit()
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cream))
            }
            Button { showBoard = true } label: {
                HStack(spacing: 6) {
                    Text("🏆").font(.system(size: 14))
                    Text(board.top.isEmpty ? "the leaderboard" : "full leaderboard · \(board.surfers) surfers")
                        .font(Theme.rounded(13, .bold))
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .black))
                }
                .foregroundStyle(Theme.ink)
            }
            .buttonStyle(SquishStyle())
        }
        .padding(16)
        .paperCard(radius: 22)
    }

    private var surfLine: String {
        if let you = board.you { return "best \(you.best.formatted()) · #\(you.rank) in the world" }
        if board.localBest > 0 { return "best \(board.localBest.formatted()) · unranked" }
        return "trains, coins, ramps. tokens make it faster."
    }

    @ViewBuilder private var shelf: some View {
        let projects = model.store.projects
        VStack(alignment: .leading, spacing: 12) {
            StrokedText(text: "YOUR APPS", font: Theme.anton(26), stroke: 2.5)
            if projects.isEmpty {
                HStack(spacing: 12) {
                    BlobHero(unit: 30, energy: 0.12)
                    Text("no apps yet. the splat is bored.\ntype something up there ↑")
                        .font(Theme.rounded(14, .bold)).foregroundStyle(Theme.ink)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .paperCard(radius: 18)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(projects) { p in
                        Button { open(p.id, nil) } label: { AppCard(project: p, building: model.studios[p.id]?.building ?? false) }
                            .buttonStyle(SquishStyle())
                            .contextMenu { cardMenu(p) }
                            .overlay(alignment: .topTrailing) {
                                Menu { cardMenu(p) } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 13, weight: .black)).foregroundStyle(Theme.ink)
                                        .frame(width: 28, height: 28)
                                        .background(Circle().fill(.white.opacity(0.94)))
                                        .overlay(Circle().strokeBorder(Theme.ink.opacity(0.35), lineWidth: 1))
                                }
                                .padding(16)
                                .accessibilityLabel("More")
                            }
                    }
                }
            }
        }
    }

    /// Rename, share, delete — the same list on the card's "…" and on a long press.
    @ViewBuilder private func cardMenu(_ p: Project) -> some View {
        Button { newTitle = p.title; renaming = p } label: { Label("Rename", systemImage: "pencil") }
        if let s = p.siteURL, let u = URL(string: s) {
            ShareLink(item: u) { Label("Share the link", systemImage: "link") }
        } else {
            ShareLink(item: model.store.exportURL(for: p)) { Label("Share HTML", systemImage: "square.and.arrow.up") }
        }
        Button(role: .destructive) { deleting = p } label: { Label("Delete", systemImage: "trash") }
    }

    private func start() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        focused = false
        let p = model.store.create(prompt: text)
        open(p.id, text)
    }
}

struct AppCard: View {
    let project: Project
    var building = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(hue: project.hue, saturation: 0.55, brightness: 0.95))
                PaperGrain(opacity: 0.12).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(project.emoji).font(.system(size: 46))
                if building {
                    VStack {
                        HStack {
                            Text("COOKING")
                                .font(Theme.black(9)).foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(Theme.red))
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(7)
                }
            }
            .frame(height: 96)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.ink, lineWidth: 2))
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title).font(Theme.black(15)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(subtitle).font(Theme.rounded(11.5, .semibold)).foregroundStyle(Theme.ink2).lineLimit(1)
            }
        }
        .padding(10)
        .paperCard(radius: 20)
    }

    private var subtitle: String {
        let when = project.updated.formatted(.relative(presentation: .named))
        return project.builds == 0 ? "not built yet" : "\(project.builds) build\(project.builds == 1 ? "" : "s") · \(when)"
    }
}
