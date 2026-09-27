import SwiftUI

/// The card above THE GALLERY on Home, there only while something is new:
/// upvotes (grouped per creation) and comments on your creations. Tap a row
/// to open that creation; × clears; "…" holds the two toggles.
struct InboxCard: View {
    @State private var inbox = SurfInbox.shared
    var onOpen: (InboxItem) -> Void

    private let shown = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.yellow)
                    Text("🔔").font(.system(size: 24))
                }
                .frame(width: 48, height: 48)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.ink, lineWidth: 2))
                VStack(alignment: .leading, spacing: 2) {
                    StrokedText(text: "NEW FOR YOU", font: Theme.anton(22), color: Theme.yellow, stroke: 2.5)
                    Text(inbox.summary.isEmpty ? "on your creations" : inbox.summary)
                        .font(Theme.rounded(12, .heavy)).foregroundStyle(Theme.ink2).lineLimit(1)
                }
                Spacer(minLength: 4)
                Menu {
                    Section("Tell me about") {
                        Toggle(isOn: Binding(get: { inbox.prefs.upvotes }, set: { v in Task { await inbox.set(upvotes: v) } })) {
                            Label("Upvotes", systemImage: "arrowtriangle.up.fill")
                        }
                        Toggle(isOn: Binding(get: { inbox.prefs.comments }, set: { v in Task { await inbox.set(comments: v) } })) {
                            Label("Comments", systemImage: "bubble.left.fill")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .black)).foregroundStyle(Theme.ink)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.94)))
                        .overlay(Circle().strokeBorder(Theme.ink.opacity(0.35), lineWidth: 1))
                }
                .accessibilityLabel("Notification settings")
                Button {
                    SurfAudio.shared.play(.tick)
                    Task { await inbox.markSeen() }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .black)).foregroundStyle(Theme.ink)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.94)))
                        .overlay(Circle().strokeBorder(Theme.ink.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(SquishStyle())
                .accessibilityLabel("Clear")
            }
            VStack(spacing: 0) {
                ForEach(Array(inbox.items.prefix(shown).enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Rectangle().fill(Theme.ink.opacity(0.1)).frame(height: 1) }
                    Button { onOpen(item) } label: { InboxRow(item: item) }
                        .buttonStyle(SquishStyle())
                }
            }
            .padding(.top, 4)
            if inbox.items.count > shown {
                Text("+ \(inbox.items.count - shown) more")
                    .font(Theme.rounded(11.5, .heavy)).foregroundStyle(Theme.ink2)
                    .padding(.leading, 30)
            }
        }
        .padding(12)
        .paperCard(radius: 20)
    }
}

/// "▲ 3 upvotes on 🐍 Snake · @jo, @max" or "💬 @jo on 🍅 Pomodoro" + the comment.
struct InboxRow: View {
    let item: InboxItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(item.isComment ? "💬" : "▲")
                .font(Theme.rounded(13, .black)).foregroundStyle(item.isComment ? Theme.ink : Theme.splat)
                .frame(width: 22, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(Theme.rounded(13.5, .heavy)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(detail).font(Theme.rounded(12.5, .semibold)).foregroundStyle(Theme.ink2).lineLimit(item.isComment ? 2 : 1)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .black)).foregroundStyle(Theme.ink2).padding(.top, 3)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .multilineTextAlignment(.leading)
    }

    private var headline: String {
        if item.isComment { return "@\(item.handle ?? "someone") on \(item.emoji) \(item.title)" }
        let n = item.count ?? 0
        return "\(n) upvote\(n == 1 ? "" : "s") on \(item.emoji) \(item.title)"
    }

    /// The second line, with when: “the comment” · 2m, or @who, @who and 3 more · 2m.
    private var detail: String {
        let when = agoLabel(item.at)
        let tail = when.isEmpty ? "" : " · \(when)"
        if item.isComment { return "“\(item.body ?? "")”" + tail }
        let names = (item.handles ?? []).map { "@\($0)" }
        let n = item.count ?? 0
        if names.isEmpty { return "tap to see it" + tail }
        let more = n - names.count
        return names.joined(separator: ", ") + (more > 0 ? " and \(more) more" : "") + tail
    }
}

// MARK: - comments on a creation

/// Read and write comments on one creation. Posting asks for a sign-in first;
/// × on a comment you may delete (yours, or any on your own creation).
struct CommentsSheet: View {
    let app: GalleryApp
    var onCount: ((Int) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var account = SurfAccount.shared
    @State private var comments: [AppComment] = []
    @State private var loading = true
    @State private var error: String?
    @State private var draft = ""
    @State private var busy = false
    @State private var signIn = false
    @State private var pendingPost = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: -4) {
                    StrokedText(text: "COMMENTS", font: Theme.anton(26), color: Theme.yellow, stroke: 2.5)
                    Text("on \(app.emoji) \(app.title)").font(Theme.rounded(12, .heavy)).foregroundStyle(Theme.ink).lineLimit(1)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .black)).foregroundStyle(Theme.ink)
                        .frame(width: 36, height: 36).background(Circle().fill(.white))
                }
                .buttonStyle(SquishStyle())
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.orange.overlay(PaperGrain(opacity: 0.08)))

            ScrollView {
                VStack(spacing: 0) {
                    if loading {
                        Text("loading…").font(Theme.rounded(13, .bold)).foregroundStyle(Theme.ink2).padding(20)
                    } else if comments.isEmpty {
                        VStack(spacing: 8) {
                            BlobHero(unit: 26, energy: 0.2)
                            Text(error ?? "no comments yet. say hi.").font(Theme.rounded(13.5, .bold)).foregroundStyle(error == nil ? Theme.ink2 : Theme.red)
                                .multilineTextAlignment(.center)
                        }
                        .padding(24)
                    } else {
                        ForEach(Array(comments.enumerated()), id: \.element.id) { i, c in
                            if i > 0 { Rectangle().fill(Theme.ink.opacity(0.1)).frame(height: 1) }
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text("@\(c.handle)").font(Theme.rounded(13, .black)).foregroundStyle(Theme.ink)
                                        Text(agoLabel(c.createdAt)).font(Theme.rounded(11, .bold)).foregroundStyle(Theme.ink2)
                                    }
                                    Text(c.body).font(Theme.rounded(14.5, .medium)).foregroundStyle(Theme.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 4)
                                if c.canDelete {
                                    Button { delete(c) } label: {
                                        Image(systemName: "xmark").font(.system(size: 11, weight: .black)).foregroundStyle(Theme.ink2)
                                            .frame(width: 26, height: 26)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Delete comment")
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                        }
                        if let error { Text(error).font(Theme.rounded(11.5, .bold)).foregroundStyle(Theme.red).padding(12) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.paper)

            HStack(alignment: .bottom, spacing: 8) {
                TextField("say something nice (or funny)", text: $draft, axis: .vertical)
                    .font(Theme.rounded(15, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.ink, lineWidth: 2))
                Button(action: post) {
                    Image(systemName: busy ? "ellipsis" : "paperplane.fill").font(.system(size: 16, weight: .black)).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(ready ? Theme.splat : Theme.ink2.opacity(0.5)))
                        .overlay(Circle().strokeBorder(Theme.ink, lineWidth: 2))
                }
                .buttonStyle(SquishStyle())
                .disabled(!ready || busy)
                .accessibilityLabel("Post")
            }
            .padding(12)
            .background(Theme.orange.overlay(PaperGrain(opacity: 0.08)))
        }
        .background(Theme.paper)
        .task { await load() }
        .sheet(isPresented: $signIn) { AccountSheet { if pendingPost { pendingPost = false; post() } } }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var ready: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func load() async {
        do {
            let r = try await account.comments(slug: app.slug)
            comments = r.comments
            onCount?(r.count)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func post() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !busy else { return }
        guard account.signedIn else { pendingPost = true; signIn = true; return }
        busy = true
        Task {
            do {
                let r = try await account.comment(slug: app.slug, body: body)
                comments.insert(r.comment, at: 0)
                onCount?(r.count)
                draft = ""
                error = nil
                SurfAudio.shared.play(.coin)
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func delete(_ c: AppComment) {
        Task {
            do {
                let n = try await account.deleteComment(slug: app.slug, id: c.id)
                comments.removeAll { $0.id == c.id }
                onCount?(n)
                SurfAudio.shared.play(.tick)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
