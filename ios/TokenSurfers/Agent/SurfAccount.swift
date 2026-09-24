import Foundation
import Observation
import SwiftUI

/// The account: a handle + password on hilma (/api/surf/auth), a bearer
/// token kept in UserDefaults. Signing in also names you on the leaderboard.
struct SurfUser: Codable, Equatable {
    let id: String
    let handle: String
}

/// One published creation as the gallery lists it.
struct GalleryApp: Identifiable, Decodable, Equatable {
    struct Parent: Decodable, Equatable { let slug: String; let title: String }
    let id: String
    let slug: String
    let title: String
    let emoji: String
    let prompt: String
    let owner: String
    var upvotes: Int
    let remixOf: Parent?
    let createdAt: String
    let updatedAt: String
    var voted: Bool
    let url: String
    var siteUrl: String? = nil     // built on the mini: the app on Vercel (html is empty)
    var html: String? = nil
    var remixes: Int? = nil
}

@Observable
@MainActor
final class SurfAccount {
    static let shared = SurfAccount()

    private(set) var user: SurfUser? {
        didSet {
            if let user, let data = try? JSONEncoder().encode(user) { UserDefaults.standard.set(data, forKey: "surf.user") }
            else { UserDefaults.standard.removeObject(forKey: "surf.user") }
        }
    }
    private(set) var token: String? {
        didSet { UserDefaults.standard.set(token, forKey: "surf.token") }
    }
    private(set) var busy = false
    private(set) var error: String?

    var signedIn: Bool { user != nil && token != nil }
    var handle: String { user?.handle ?? "" }

    private init() {
        token = UserDefaults.standard.string(forKey: "surf.token")
        if let data = UserDefaults.standard.data(forKey: "surf.user") { user = try? JSONDecoder().decode(SurfUser.self, from: data) }
    }

    // MARK: requests

    private struct Failure: Decodable { let error: String }

    /// A request against hilma with the bearer token when signed in.
    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, query: [String: String] = [:]) async throws -> Data {
        var comps = URLComponents(url: backendURL().appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(Secrets.appKey, forHTTPHeaderField: "x-surf-key")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, token != nil, path.hasPrefix("api/surf/auth/me") { signOut() }
        guard (200..<300).contains(status) else {
            throw SurfAPIError(message: (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "server said \(status)")
        }
        return data
    }

    private struct AuthPayload: Decodable { let token: String; let user: SurfUser }

    @discardableResult
    func authenticate(handle: String, password: String, create: Bool) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let data = try await request(create ? "api/surf/auth/signup" : "api/surf/auth/login", method: "POST",
                                         body: ["handle": handle, "password": password])
            let payload = try JSONDecoder().decode(AuthPayload.self, from: data)
            token = payload.token
            user = payload.user
            error = nil
            Leaderboard.shared.handle = payload.user.handle
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func signOut() {
        token = nil
        user = nil
    }

    // MARK: creations

    private struct Wrapped: Decodable { let app: GalleryApp }
    private struct Wrapped2: Decodable { let apps: [GalleryApp] }

    func publish(project: Project, html: String, siteURL: String? = nil) async throws -> GalleryApp {
        var body: [String: Any] = [
            "client_id": project.id.uuidString.lowercased(), "title": project.title, "emoji": project.emoji,
            "prompt": project.prompts.first ?? "", "html": html, "remix_of": project.remixOf ?? "",
        ]
        if let siteURL { body["site_url"] = siteURL }
        let data = try await request("api/surf/apps", method: "POST", body: body)
        return try JSONDecoder().decode(Wrapped.self, from: data).app
    }

    func unpublish(slug: String) async throws {
        _ = try await request("api/surf/apps/\(slug)", method: "DELETE")
    }

    func gallery(sort: String, mine: Bool = false) async throws -> [GalleryApp] {
        let data = try await request("api/surf/apps", query: mine ? ["sort": sort, "mine": "1"] : ["sort": sort])
        return try JSONDecoder().decode(Wrapped2.self, from: data).apps
    }

    func fetch(slug: String) async throws -> GalleryApp {
        let data = try await request("api/surf/apps/\(slug)")
        return try JSONDecoder().decode(Wrapped.self, from: data).app
    }

    private struct Vote: Decodable { let voted: Bool; let upvotes: Int }

    func upvote(slug: String) async throws -> (voted: Bool, upvotes: Int) {
        let data = try await request("api/surf/apps/\(slug)/upvote", method: "POST")
        let v = try JSONDecoder().decode(Vote.self, from: data)
        return (v.voted, v.upvotes)
    }

    /// Flags a creation; works signed out too.
    func report(slug: String, reason: String) async throws {
        _ = try await request("api/surf/apps/\(slug)/report", method: "POST", body: ["reason": reason])
    }
}

// MARK: - sign in / sign up

struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var account = SurfAccount.shared
    @State private var handle = ""
    @State private var password = ""
    @State private var create = true
    @FocusState private var focus: Field?
    var onDone: (() -> Void)?

    enum Field { case handle, password }

    var body: some View {
        ZStack {
            Sunburst(spin: false).ignoresSafeArea()
            PaperGrain(opacity: 0.09).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    BlobHero(unit: 40, mood: .cool)
                    VStack(spacing: -8) {
                        StrokedText(text: create ? "JOIN THE" : "WELCOME", font: Theme.anton(30), stroke: 3)
                        StrokedText(text: create ? "SURFERS" : "BACK", font: Theme.anton(40), color: Theme.yellow, stroke: 3.5)
                    }
                    Text(create ? "one handle for the gallery and the leaderboard.\nno email. no spam. just vibes."
                                : "sign in to publish, upvote and remix.")
                        .font(Theme.rounded(13, .bold)).multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: Theme.ink.opacity(0.6), radius: 0, y: 1.5)
                    VStack(spacing: 10) {
                        field("handle", text: $handle, secure: false, field: .handle)
                        field("password", text: $password, secure: true, field: .password)
                    }
                    if let e = account.error {
                        Text(e).font(Theme.rounded(12.5, .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(Theme.red))
                    }
                    ChunkyButton(title: account.busy ? "…" : (create ? "CREATE ACCOUNT" : "SIGN IN"),
                                 fill: ready ? Theme.splat : Theme.ink2.opacity(0.5), action: go)
                        .disabled(!ready || account.busy)
                    Button { create.toggle() } label: {
                        Text(create ? "already surfing? sign in" : "new here? create an account")
                            .font(Theme.rounded(13, .heavy)).foregroundStyle(.white).underline()
                            .shadow(color: Theme.ink.opacity(0.6), radius: 0, y: 1.5)
                    }
                    Button { dismiss() } label: {
                        Text("not now").font(Theme.rounded(12.5, .bold)).foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.top, 4)
                }
                .padding(24)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { focus = .handle }
        .presentationDetents([.large])
    }

    private var ready: Bool { handle.trimmingCharacters(in: .whitespaces).count >= 2 && password.count >= 4 }

    private func field(_ placeholder: String, text: Binding<String>, secure: Bool, field: Field) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .font(Theme.heavy(20))
        .foregroundStyle(Theme.ink)
        .focused($focus, equals: field)
        .submitLabel(field == .handle ? .next : .go)
        .onSubmit { if field == .handle { focus = .password } else { go() } }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.ink, lineWidth: 2.5))
    }

    private func go() {
        guard ready else { return }
        Task {
            if await account.authenticate(handle: handle, password: password, create: create) {
                dismiss()
                onDone?()
            }
        }
    }
}
