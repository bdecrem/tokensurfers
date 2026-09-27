import Foundation
import Observation

/// The "new for you" card on Home: upvotes and comments on your creations
/// since you last cleared it (GET /api/surf/inbox). Nothing is pushed and
/// nothing polls: one GET when Home first shows, then at most one an hour
/// when the app comes back to the front (`minInterval`), and a forced one on
/// sign-in. The × and the two toggles PATCH and take the fresh answer back, so
/// they never add a GET. The last answer is cached so the card is there on
/// launch, not a second later. The card itself is static SwiftUI: no timers,
/// no per-frame work.
struct InboxItem: Identifiable, Decodable, Equatable {
    let kind: String            // "upvotes" (grouped per creation) or "comment"
    let slug: String
    let title: String
    let emoji: String
    let at: String
    var count: Int? = nil       // upvotes
    var handles: [String]? = nil
    var commentID: String? = nil
    var handle: String? = nil   // comment
    var body: String? = nil

    var id: String { commentID ?? "upvotes-\(slug)" }
    var isComment: Bool { kind == "comment" }

    private enum CodingKeys: String, CodingKey { case kind, slug, title, emoji, at, count, handles, commentID = "id", handle, body }
}

struct InboxPrefs: Codable, Equatable {
    var upvotes = true
    var comments = true
}

private struct InboxPayload: Decodable {
    let seenAt: String
    let prefs: InboxPrefs
    let items: [InboxItem]
}

@Observable
@MainActor
final class SurfInbox {
    static let shared = SurfInbox()

    private(set) var items: [InboxItem] = []
    private(set) var prefs = InboxPrefs()
    private var lastFetch: Date = .distantPast
    /// How long a fetch is good for; the app coming to the front inside it asks nothing.
    static let minInterval: TimeInterval = 60 * 60

    private init() {
        if let data = UserDefaults.standard.data(forKey: "surf.inbox"), let p = try? JSONDecoder().decode(InboxPayload.self, from: data) {
            items = p.items
            prefs = p.prefs
        }
    }

    var upvoteCount: Int { items.filter { !$0.isComment }.reduce(0) { $0 + ($1.count ?? 0) } }
    var commentCount: Int { items.filter(\.isComment).count }

    /// One line under the title: "3 upvotes · 1 comment".
    var summary: String {
        var parts: [String] = []
        if upvoteCount > 0 { parts.append("\(upvoteCount) upvote\(upvoteCount == 1 ? "" : "s")") }
        if commentCount > 0 { parts.append("\(commentCount) comment\(commentCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// Asks hilma, at most once per `minInterval` unless forced. Signed out, the card is empty.
    func refresh(force: Bool = false) async {
        guard SurfAccount.shared.signedIn else { items = []; return }
        if !force, Date().timeIntervalSince(lastFetch) < Self.minInterval { return }
        lastFetch = .now
        do {
            let data = try await SurfAccount.shared.request("api/surf/inbox")
            try apply(data)
        } catch {
            print("[inbox] refresh: \(error.localizedDescription)")   // best effort: keep what we have
        }
    }

    /// The × on the card: everything so far is seen.
    func markSeen() async {
        items = []
        await patch(["seen": true])
    }

    func set(upvotes: Bool) async {
        prefs.upvotes = upvotes
        if !upvotes { items.removeAll { !$0.isComment } }
        await patch(["upvotes": upvotes])
    }

    func set(comments: Bool) async {
        prefs.comments = comments
        if !comments { items.removeAll(where: \.isComment) }
        await patch(["comments": comments])
    }

    private func patch(_ body: [String: Any]) async {
        do {
            let data = try await SurfAccount.shared.request("api/surf/inbox", method: "PATCH", body: body)
            try apply(data)
        } catch {
            print("[inbox] patch: \(error.localizedDescription)")
        }
    }

    private func apply(_ data: Data) throws {
        let p = try JSONDecoder().decode(InboxPayload.self, from: data)
        items = p.items
        prefs = p.prefs
        UserDefaults.standard.set(data, forKey: "surf.inbox")
    }

    func clearCache() {
        items = []
        UserDefaults.standard.removeObject(forKey: "surf.inbox")
    }
}

// MARK: - comments on a creation

struct AppComment: Identifiable, Decodable, Equatable {
    let id: String
    let handle: String
    let body: String
    let createdAt: String
    let mine: Bool
    let canDelete: Bool
}

extension SurfAccount {
    private struct CommentList: Decodable { let comments: [AppComment]; let count: Int }
    private struct Posted: Decodable { let comment: AppComment; let comments: Int }
    private struct Deleted: Decodable { let comments: Int }

    func comments(slug: String) async throws -> (comments: [AppComment], count: Int) {
        let data = try await request("api/surf/apps/\(slug)/comments")
        let l = try JSONDecoder().decode(CommentList.self, from: data)
        return (l.comments, l.count)
    }

    func comment(slug: String, body: String) async throws -> (comment: AppComment, count: Int) {
        let data = try await request("api/surf/apps/\(slug)/comments", method: "POST", body: ["body": body])
        let p = try JSONDecoder().decode(Posted.self, from: data)
        return (p.comment, p.comments)
    }

    func deleteComment(slug: String, id: String) async throws -> Int {
        let data = try await request("api/surf/apps/\(slug)/comments/\(id)", method: "DELETE")
        return try JSONDecoder().decode(Deleted.self, from: data).comments
    }
}

/// "now", "2m", "3h", "5d" from a server timestamp.
func agoLabel(_ iso: String, now: Date = .now) -> String {
    guard let d = parseISO(iso) else { return "" }
    let s = max(0, Int(now.timeIntervalSince(d)))
    if s < 60 { return "now" }
    let m = s / 60
    if m < 60 { return "\(m)m" }
    let h = m / 60
    if h < 24 { return "\(h)h" }
    let days = h / 24
    return days < 30 ? "\(days)d" : "\(days / 30)mo"
}

/// Postgres timestamps come with six fractional digits; ISO8601DateFormatter wants three or none.
func parseISO(_ iso: String) -> Date? {
    if let d = ISOFormat.fractional.date(from: iso) { return d }
    var trimmed = iso
    if let dot = iso.firstIndex(of: "."), let end = iso[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
        trimmed = String(iso[..<dot]) + String(iso[end...])
    }
    return ISOFormat.plain.date(from: trimmed)
}

private enum ISOFormat {
    static let fractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    static let plain: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
}
