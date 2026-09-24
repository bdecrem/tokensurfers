import Foundation

/// The phone's side of `apps/tokensurfers/agent`: Claude Code running in a
/// workspace on the mini. Three verbs (prompt, now, stop) and a long-polled
/// event feed; `TS_AGENT=http://localhost:3910` points the simulator at a
/// server on this Mac.
enum AgentAPI {
    struct Event {
        let seq: Int
        let type: String
        let data: [String: Any]
    }

    struct State {
        var running = false
        var sessionId: String?
        var deployUrl: String?
        var recap: String?
        var cost = 0.0
        var builds = 0

        init(_ d: [String: Any]) {
            running = d["running"] as? Bool ?? false
            sessionId = d["sessionId"] as? String
            deployUrl = d["deployUrl"] as? String
            recap = d["recap"] as? String
            cost = d["cost"] as? Double ?? 0
            builds = d["builds"] as? Int ?? 0
        }
    }

    struct Poll {
        let events: [Event]
        let seq: Int
        let state: State
        let gap: Bool
    }

    static func base() -> URL {
        if let raw = ProcessInfo.processInfo.environment["TS_AGENT"], let url = URL(string: raw) { return url }
        return Secrets.agentURL
    }

    /// Idle: starts a build. Running: the server queues it for Splat's next step. Returns whether it was queued.
    static func prompt(_ id: UUID, text: String) async throws -> Bool {
        let r = try await call("prompt", id, body: ["text": text])
        return r["queued"] as? Bool ?? false
    }

    /// Interrupt the turn; the queued notes (plus `text`, if any) go in as the next message.
    static func now(_ id: UUID, text: String?) async throws {
        var body: [String: Any] = [:]
        if let text, !text.isEmpty { body["text"] = text }
        _ = try await call("now", id, body: body)
    }

    /// Interrupt and end the build. Returns the notes that never reached Splat.
    static func stop(_ id: UUID) async throws -> [String] {
        let r = try await call("stop", id, body: [:])
        return r["notes"] as? [String] ?? []
    }

    static func events(_ id: UUID, after: Int, wait: Int) async throws -> Poll {
        let r = try await get("events", id, query: "after=\(after)&wait=\(wait)", timeout: Double(wait) + 20)
        let events = (r["events"] as? [[String: Any]] ?? []).compactMap { e -> Event? in
            guard let seq = e["seq"] as? Int, let type = e["type"] as? String else { return nil }
            return Event(seq: seq, type: type, data: e)
        }
        return Poll(events: events, seq: r["seq"] as? Int ?? after,
                    state: State(r["state"] as? [String: Any] ?? [:]), gap: r["gap"] as? Bool ?? false)
    }

    static func state(_ id: UUID) async throws -> (seq: Int, state: State) {
        let r = try await get("state", id, query: "", timeout: 20)
        return (r["seq"] as? Int ?? 0, State(r["state"] as? [String: Any] ?? [:]))
    }

    // MARK: plumbing

    private static func path(_ verb: String, _ id: UUID) -> String { "p/\(id.uuidString.lowercased())/\(verb)" }

    private static func call(_ verb: String, _ id: UUID, body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: base().appendingPathComponent(path(verb, id)))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(Secrets.appKey, forHTTPHeaderField: "x-surf-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private static func get(_ verb: String, _ id: UUID, query: String, timeout: Double) async throws -> [String: Any] {
        var url = base().appendingPathComponent(path(verb, id))
        if !query.isEmpty { url = URL(string: url.absoluteString + "?" + query) ?? url }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue(Secrets.appKey, forHTTPHeaderField: "x-surf-key")
        return try await send(req)
    }

    private static func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 || status == 202 else {
            throw SurfAPIError(message: obj["error"] as? String ?? "the agent server said \(status)",
                               transient: [502, 503, 504].contains(status))
        }
        return obj
    }
}
