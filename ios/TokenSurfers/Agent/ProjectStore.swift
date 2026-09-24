import Foundation
import Observation

/// One vibe-coded app: metadata here, the HTML in Documents/apps/<id>.html.
struct Project: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String = "untitled"
    var emoji: String = "✨"
    var created: Date = .now
    var updated: Date = .now
    var prompts: [String] = []
    var recap: String = ""
    var builds: Int = 0
    var tokens: Int = 0
    var hue: Double = Double.random(in: 0...1)
    var remoteSlug: String? = nil     // published in the gallery as /surf/a/<slug>
    var remixOf: String? = nil        // the gallery slug this was remixed from
    var siteURL: String? = nil        // built by Claude Code on the mini: the deployed app (no local html)
}

@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    var totalTokens: Int = 0
    var bestScore: Int = 0

    private let dir: URL
    private var indexURL: URL { dir.appendingPathComponent("projects.json") }
    private var statsURL: URL { dir.appendingPathComponent("stats.json") }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("TokenSurfers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("apps"), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([Project].self, from: data) {
            projects = list.sorted { $0.updated > $1.updated }
        }
        if let data = try? Data(contentsOf: statsURL),
           let s = try? JSONDecoder().decode([String: Int].self, from: data) {
            totalTokens = s["tokens"] ?? 0
            bestScore = s["best"] ?? 0
        }
    }

    func htmlURL(_ id: UUID) -> URL { dir.appendingPathComponent("apps/\(id.uuidString).html") }

    func html(for id: UUID) -> String {
        (try? String(contentsOf: htmlURL(id), encoding: .utf8)) ?? ""
    }

    func saveHTML(_ html: String, for id: UUID) {
        try? html.write(to: htmlURL(id), atomically: true, encoding: .utf8)
    }

    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }

    @discardableResult
    func create(prompt: String) -> Project {
        var p = Project()
        p.title = "new app"
        p.emoji = "🥚"
        p.prompts = []
        projects.insert(p, at: 0)
        persist()
        return p
    }

    func update(_ p: Project) {
        if let i = projects.firstIndex(where: { $0.id == p.id }) {
            projects[i] = p
        } else {
            projects.insert(p, at: 0)
        }
        projects.sort { $0.updated > $1.updated }
        persist()
    }

    func delete(_ id: UUID) {
        projects.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: htmlURL(id))
        persist()
    }

    func addTokens(_ n: Int) {
        totalTokens += n
        persistStats()
    }

    func reportScore(_ s: Int) {
        guard s > bestScore else { return }
        bestScore = s
        persistStats()
    }

    /// A named copy of the HTML for the share sheet.
    func exportURL(for p: Project) -> URL {
        let safe = p.title.replacingOccurrences(of: "[^A-Za-z0-9 _-]", with: "", options: .regularExpression)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent((safe.isEmpty ? "app" : safe) + ".html")
        try? html(for: p.id).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(projects) { try? data.write(to: indexURL, options: .atomic) }
    }

    private func persistStats() {
        if let data = try? JSONEncoder().encode(["tokens": totalTokens, "best": bestScore]) {
            try? data.write(to: statsURL, options: .atomic)
        }
    }
}
