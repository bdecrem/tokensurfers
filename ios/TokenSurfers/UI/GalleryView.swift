import SwiftUI
import WebKit

/// The gallery: what everyone published, top or new. Tap one to try it,
/// upvote it, or remix it into your own apps.
struct GalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var account = SurfAccount.shared
    @State private var sort = "top"
    @State private var apps: [GalleryApp] = []
    @State private var loading = false
    @State private var error: String?
    @State private var open: GalleryApp?
    @State private var signIn = false
    var onOpenProject: (UUID) -> Void

    var body: some View {
        ZStack {
            Theme.navy.ignoresSafeArea()
            Starfield().ignoresSafeArea().opacity(0.35)
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .black)).foregroundStyle(Theme.ink)
                            .frame(width: 38, height: 38).background(Circle().fill(.white))
                    }
                    .buttonStyle(SquishStyle())
                    .accessibilityLabel("Close")
                    Spacer()
                    HStack(spacing: 0) {
                        ForEach(["top", "new"], id: \.self) { s in
                            Button { sort = s; Task { await load() } } label: {
                                Text(s.uppercased()).font(Theme.black(12))
                                    .foregroundStyle(sort == s ? .white : Theme.ink)
                                    .frame(width: 56, height: 30)
                                    .background(Capsule().fill(sort == s ? Theme.ink : .clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                    .background(Capsule().fill(.white))
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)

                VStack(spacing: -10) {
                    StrokedText(text: "THE", font: Theme.anton(32), stroke: 3)
                    StrokedText(text: "GALLERY", font: Theme.anton(48), color: Theme.yellow, stroke: 3.5)
                }
                .padding(.top, 4)
                Text("what everyone surfed up. tap to play, remix to make it yours.")
                    .font(Theme.rounded(12.5, .heavy)).foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(apps) { app in
                            Button { open = app } label: { GalleryCard(app: app) }
                                .buttonStyle(SquishStyle())
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 30)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    if apps.isEmpty {
                        Text(loading ? "loading…" : (error ?? "nothing here yet. publish something from a build's ••• menu."))
                            .font(Theme.rounded(14, .bold)).foregroundStyle(Theme.ink)
                            .padding(16).frame(maxWidth: .infinity).paperCard()
                            .padding(.horizontal, 14)
                    }
                }
                .refreshable { await load() }
            }
        }
        .task {
            await load()
            if let slug = ProcessInfo.processInfo.environment["TS_GALLERY"], slug != "1", let a = apps.first(where: { $0.slug == slug }) ?? apps.first {
                try? await Task.sleep(for: .seconds(1))
                open = a
            }
        }
        .sheet(item: $open) { app in
            GalleryAppView(app: app, onOpenProject: { id in open = nil; dismiss(); onOpenProject(id) })
                .environment(model)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            apps = try await account.gallery(sort: sort)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct GalleryCard: View {
    let app: GalleryApp

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(hue: Double(abs(app.slug.hashValue) % 360) / 360, saturation: 0.5, brightness: 0.95))
                PaperGrain(opacity: 0.12).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(app.emoji).font(.system(size: 42))
                VStack {
                    HStack {
                        Spacer()
                        Text("▲ \(app.upvotes)")
                            .font(Theme.black(10)).foregroundStyle(app.voted ? .white : Theme.ink)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(app.voted ? Theme.splat : .white.opacity(0.85)))
                    }
                    Spacer()
                }
                .padding(7)
            }
            .frame(height: 92)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.ink, lineWidth: 2))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.title).font(Theme.black(14)).foregroundStyle(Theme.ink).lineLimit(1)
                Text("@\(app.owner)" + (app.remixOf != nil ? " · remix" : "")).font(Theme.rounded(11, .semibold)).foregroundStyle(Theme.ink2).lineLimit(1)
            }
        }
        .padding(10)
        .paperCard(radius: 20)
    }
}

/// One creation: play it, upvote it, remix it into your apps.
struct GalleryAppView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State var app: GalleryApp
    @State private var account = SurfAccount.shared
    @State private var html: String?
    @State private var busy = false
    @State private var error: String?
    @State private var signIn = false
    @State private var pendingVote = false
    @State private var reportSheet = false
    @State private var reported = false
    var onOpenProject: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 15, weight: .black)).foregroundStyle(Theme.ink)
                        .frame(width: 38, height: 38).background(Circle().fill(.white))
                }
                .buttonStyle(SquishStyle())
                HStack(spacing: 6) {
                    Text(app.emoji).font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(app.title).font(Theme.black(15)).foregroundStyle(Theme.ink).lineLimit(1)
                        Text("by @\(app.owner)" + (app.remixOf.map { " · remix of \($0.title)" } ?? ""))
                            .font(Theme.rounded(11, .semibold)).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(Capsule().fill(.white))
                Spacer(minLength: 0)
                Button(action: vote) {
                    Text("▲ \(app.upvotes)")
                        .font(Theme.black(13)).foregroundStyle(app.voted ? .white : Theme.ink)
                        .padding(.horizontal, 12).frame(height: 38)
                        .background(Capsule().fill(app.voted ? Theme.splat : .white))
                        .overlay(Capsule().strokeBorder(Theme.ink, lineWidth: app.voted ? 0 : 1.5))
                }
                .buttonStyle(SquishStyle())
                .accessibilityLabel("Upvote")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.orange.overlay(PaperGrain(opacity: 0.08)))

            ZStack {
                Color.white
                if let site = app.siteUrl.flatMap({ URL(string: $0) }) {
                    SiteWebView(url: site, version: 1)
                } else if let html {
                    PreviewWebView(html: html, version: 1, projectID: UUID(uuidString: app.id) ?? UUID())
                } else {
                    VStack(spacing: 10) {
                        BlobHero(unit: 34)
                        Text(error ?? "loading…").font(Theme.rounded(14, .bold)).foregroundStyle(Theme.ink)
                    }
                }
            }

            VStack(spacing: 8) {
                if !app.prompt.isEmpty {
                    Text("“\(app.prompt)”").font(Theme.rounded(12.5, .semibold)).foregroundStyle(Theme.ink)
                        .lineLimit(2).multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    if let site = app.siteUrl.flatMap({ URL(string: $0) }) {
                        // built on the mini: nothing to copy yet, open it big instead
                        ChunkyButton(title: "OPEN IT ↗", fill: Theme.splat, height: 46) { UIApplication.shared.open(site) }
                    } else {
                        ChunkyButton(title: busy ? "…" : "REMIX IT 🔁", fill: Theme.splat, height: 46, action: remix)
                            .disabled(html == nil || busy)
                    }
                    ShareLink(item: URL(string: app.siteUrl ?? app.url)!) {   // the app itself when it has its own address
                        Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .black)).foregroundStyle(Theme.ink)
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(.white).overlay(Circle().strokeBorder(Theme.ink, lineWidth: 2.5)))
                            .background(Circle().fill(Theme.ink).offset(y: 4))
                    }
                    .buttonStyle(SquishStyle())
                }
                if let error { Text(error).font(Theme.rounded(11.5, .bold)).foregroundStyle(Theme.red) }
                Button(reported ? "reported. thanks." : "report this creation") { if !reported { reportSheet = true } }
                    .font(Theme.rounded(11.5, .semibold)).foregroundStyle(Theme.ink2).underline(!reported)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Report this creation")
            }
            .padding(12)
            .background(Theme.orange.overlay(PaperGrain(opacity: 0.08)))
        }
        .confirmationDialog("Report this creation?", isPresented: $reportSheet, titleVisibility: .visible) {
            ForEach(["it's offensive or hateful", "it's harmful or a scam", "it's someone else's work", "something else"], id: \.self) { why in
                Button(why) { report(why) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We look at every report. Owners can also unpublish their own creations.")
        }
        .task {
            do {
                let full = try await account.fetch(slug: app.slug)
                html = full.html ?? ""
                if let s = full.siteUrl { app.siteUrl = s }
                app.upvotes = full.upvotes
                app.voted = full.voted
            } catch {
                self.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $signIn) { AccountSheet { if pendingVote { pendingVote = false; vote() } } }
    }

    private func vote() {
        guard account.signedIn else { pendingVote = true; signIn = true; return }
        Task {
            do {
                let v = try await account.upvote(slug: app.slug)
                app.voted = v.voted
                app.upvotes = v.upvotes
                SurfAudio.shared.play(v.voted ? .coin : .tick)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func report(_ why: String) {
        Task {
            do {
                try await account.report(slug: app.slug, reason: why)
                reported = true
                SurfAudio.shared.play(.tick)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Copies the creation into your apps as a new project and opens it.
    private func remix() {
        guard let html else { return }
        busy = true
        var p = Project()
        p.title = app.title + " remix"
        p.emoji = app.emoji
        p.prompts = app.prompt.isEmpty ? [] : [app.prompt]
        p.recap = "remixed from @\(app.owner)"
        p.builds = 1
        p.remixOf = app.slug
        model.store.saveHTML(html, for: p.id)
        model.store.update(p)
        busy = false
        onOpenProject(p.id)
    }
}
