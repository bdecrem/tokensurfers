import Foundation
import Observation
import AVFoundation

/// One open project: the agent loop, what the stage shows, and the game it feeds.
///
/// The loop is the Jambot runAgent shape (see apps/tokensurfers/CLAUDE.md):
/// stream a Messages call, run every tool_use in order, send all results back
/// in one user message, repeat until end_turn. Each request starts a fresh
/// conversation that carries the current file, so history never grows past
/// one build and thinking blocks are always replayed untouched.
@Observable
@MainActor
final class Studio {
    enum Phase: Equatable {
        case idle, thinking, writing, editing, reading, running, done
        case failed(String)
    }
    enum StageTab: String { case app, code }
    /// Where the agent runs: Claude Code on the mini (`apps/tokensurfers/agent`),
    /// or the original four-tool loop on the phone (one index.html, no deploy).
    enum Engine: String { case remote, local }
    static var engine: Engine {
        get { Engine(rawValue: UserDefaults.standard.string(forKey: "surf.engine") ?? "") ?? .remote }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "surf.engine") }
    }
    enum Cutaway: Equatable { case tokenur, contextino, hallucinello, absolutelyRight }

    /// Something the user said while Splat was working. It waits in `queue`
    /// until the current step ends, then rides into the model's next turn next
    /// to the tool results (the way Claude Code injects queued messages).
    struct Note: Identifiable, Equatable {
        let id = UUID()
        let text: String
        var voice = false
    }

    /// One line of the live feed: Splat's actions and your notes, interleaved.
    struct FeedItem: Identifiable, Equatable {
        enum Kind: Equatable { case splat(tool: String), you(delivered: Bool), bug, clean, done }
        let id = UUID()
        var kind: Kind
        var text: String
        var noteID: UUID?
    }

    let store: ProjectStore
    private(set) var project: Project
    let game = SurfEngine()

    private(set) var html: String
    private(set) var phase: Phase = .idle
    private(set) var caption = ""
    private(set) var captionID = 0
    private(set) var captionIsFiller = false
    private(set) var subtitle = ""
    private(set) var liveCode = ""
    private(set) var patchOld = ""
    private(set) var patchNew = ""
    private(set) var isPatch = false
    var stageTab: StageTab = .app
    var stagePinned = false
    private(set) var cutaway: Cutaway?
    private(set) var previewVersion = 0
    private(set) var outputTokens = 0
    private(set) var inputTokens = 0
    private(set) var lastBugs = 0
    private(set) var steps = 0
    private(set) var lastPrompt = ""
    private(set) var queue: [Note] = []
    private(set) var feed: [FeedItem] = []
    /// Notes that reached the model this build (saved with the project's prompts).
    private var delivered: [String] = []

    var building: Bool {
        switch phase {
        case .idle, .done, .failed: return false
        default: return true
        }
    }

    private var task: Task<Void, Never>?
    private var call: Task<Turn, Error>?
    private var interrupting = false
    private let narrator = Narrator()
    private var lastCaptionAt = Date()
    private var usedFillers: Set<String> = []
    private var shownCutaways: Set<Cutaway> = []
    private var buildStart = Date()

    // the remote engine
    /// The deployed app, when Claude Code on the mini built it.
    private(set) var siteURL: URL?
    /// The last file the agent wrote, for the CODE stage between builds.
    private(set) var remoteCode = ""
    private(set) var codePath = ""
    private var lastSeq = 0
    private var inputSeen: [String: Int] = [:]

    /// A project built on the mini stays there; a fresh one follows the setting.
    var remote: Bool { project.siteURL != nil || (html.isEmpty && Self.engine == .remote) }

    init(store: ProjectStore, project: Project) {
        self.store = store
        self.project = project
        self.html = store.html(for: project.id)
        self.siteURL = project.siteURL.flatMap { URL(string: $0) }
        self.stageTab = (html.isEmpty && project.siteURL == nil) ? .code : .app
    }

    // MARK: public

    /// Idle: start a build. Building: queue it for the next step.
    func send(_ prompt: String, voice: Bool = false) {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        if building {
            let n = Note(text: p, voice: voice)
            queue.append(n)
            log(.you(delivered: false), p, note: n.id)
            SurfAudio.shared.play(.swipe)
            if remote {
                // the server keeps the note for Splat's next tool result; `note_in` flips the chip
                let id = project.id
                Task { do { _ = try await AgentAPI.prompt(id, text: p) } catch { self.agentLog("note didn't reach the mini: \(error.localizedDescription)") } }
            }
            return
        }
        log(.you(delivered: true), p)
        let useRemote = remote
        task = Task { if useRemote { await runRemote(p) } else { await run(p) } }
    }

    /// Take a queued note back before Splat sees it.
    func unqueue(_ id: UUID) {
        queue.removeAll { $0.id == id }
        feed.removeAll { $0.noteID == id }
    }

    /// Don't wait for the step to end: drop the half-streamed turn and hand
    /// Splat the queued notes right now. (A tool that is already running, like
    /// the test drive, still finishes; the notes go with its result.)
    func deliverNow() {
        guard !queue.isEmpty else { return }
        if remote {
            let id = project.id
            Task { do { try await AgentAPI.now(id, text: nil) } catch { self.agentLog("⚡ now failed: \(error.localizedDescription)") } }
            return
        }
        guard let call else { return }
        interrupting = true
        call.cancel()
    }

    /// Anything still queued when a build ends early goes back to the composer.
    func takeQueue() -> [String] {
        let texts = queue.map(\.text)
        for n in queue { feed.removeAll { $0.noteID == n.id } }
        queue = []
        return texts
    }

    /// The mic is open: Splat stops talking so he doesn't hear himself.
    func setListening(_ on: Bool) { narrator.held = on }

    func stop() {
        agentLog("stopped by the user")
        if remote {
            let id = project.id
            Task { _ = try? await AgentAPI.stop(id) }
        }
        task?.cancel()
        task = nil
        call?.cancel()
        call = nil
        interrupting = false
        narrator.stop()
        phase = .idle
        setCaption("ok ok. i stopped 🛑", speak: false)
    }

    func retry() {
        guard !lastPrompt.isEmpty else { return }
        send(lastPrompt)
    }

    func rename(_ title: String) {
        project.title = title
        store.update(project)
    }

    func setRemoteSlug(_ slug: String?) {
        project.remoteSlug = slug
        store.update(project)
    }

    var codeForDisplay: String { liveCode.isEmpty ? (html.isEmpty ? remoteCode : html) : liveCode }

    // MARK: the loop

    private func run(_ prompt: String) async {
        lastPrompt = prompt
        phase = .thinking
        outputTokens = 0
        inputTokens = 0
        lastBugs = 0
        steps = 0
        usedFillers = []
        shownCutaways = []
        delivered = []
        subtitle = ""
        liveCode = ""
        isPatch = false
        interrupting = false
        buildStart = .now
        if !stagePinned { stageTab = .code }
        setCaption(html.isEmpty ? "so it's \(clockString()). new app just dropped" : "they said: \(shortPrompt(prompt))", speak: true)
        agentLog("build: \(shortPrompt(prompt)) (\(html.isEmpty ? "new app" : "\(lineCount(html)) lines"))")

        let filler = Task { await fillerLoop() }
        defer { filler.cancel() }

        var messages: [[String: Any]] = [["role": "user", "content": firstMessage(prompt)]]
        var recap = ""
        var budget = 20
        var calls = 0
        var retries = 0
        /// A note batch is in the conversation and the file hasn't been touched since.
        var noteOpen = false
        var nudged = false
        do {
            while calls < budget {
                calls += 1
                try Task.checkCancellation()
                let turn: Turn
                do {
                    let c = Task { try await self.callModel(messages) }
                    call = c
                    turn = try await c.value
                    call = nil
                    interrupting = false
                } catch where interrupting && !Task.isCancelled {
                    // "send now": forget the half-written turn, add the notes to the last user message
                    interrupting = false
                    call = nil
                    liveCode = ""
                    isPatch = false
                    phase = .thinking
                    agentLog("call \(calls) interrupted (⚡ now), \(queue.count) note(s) go in")
                    Self.append(takeNotes(), toLastUserMessageOf: &messages)
                    noteOpen = true
                    nudged = false
                    budget = min(32, budget + 4)
                    continue
                } catch let e where !Task.isCancelled && Self.isTransient(e) && retries < 2 {
                    // overloaded, rate limited, a dropped connection: the conversation is intact, go again
                    retries += 1
                    call = nil
                    calls -= 1
                    liveCode = ""
                    isPatch = false
                    phase = .thinking
                    agentLog("call failed: \(e.localizedDescription) — retry \(retries) in \(retries * 3) s")
                    setCaption("server hiccup. retrying 🔁", speak: false, filler: true)
                    try await Task.sleep(for: .seconds(Double(retries) * 3))
                    continue
                }
                messages.append(["role": "assistant", "content": turn.content])
                if !turn.text.isEmpty { recap = turn.text }
                agentLog("call \(calls): \(turn.stopReason), tools \(turn.toolCalls.map(\.name)), \(outputTokens) tok out, \(inputTokens) in\(turn.text.isEmpty ? "" : ", text: \(shortPrompt(turn.text))")")

                switch turn.stopReason {
                case "tool_use":
                    var results: [[String: Any]] = []
                    for c in turn.toolCalls {
                        try Task.checkCancellation()
                        results.append(await execute(c))
                        if c.name == "write_file" || c.name == "edit_file" { noteOpen = false }
                    }
                    if !queue.isEmpty {
                        results += takeNotes()
                        noteOpen = true
                        nudged = false
                        budget = min(32, budget + 4)
                    }
                    messages.append(["role": "user", "content": results])
                    phase = .thinking
                case "pause_turn":
                    continue
                case "max_tokens":
                    guard !turn.toolCalls.isEmpty else { break }
                    var results: [[String: Any]] = turn.toolCalls.map {
                        ["type": "tool_result", "tool_use_id": $0.id, "is_error": true,
                         "content": "Your output hit max_tokens and this tool input was cut off. Make smaller edits with edit_file."]
                    }
                    if !queue.isEmpty { results += takeNotes(); noteOpen = true; nudged = false }
                    messages.append(["role": "user", "content": results])
                    continue
                case "refusal":
                    throw SurfAPIError(message: "the model declined this one")
                default:
                    // notes that came in while the recap was being written: one more round
                    if !queue.isEmpty {
                        messages.append(["role": "user", "content": takeNotes()])
                        noteOpen = true
                        nudged = false
                        budget = min(32, budget + 4)
                        phase = .thinking
                        continue
                    }
                    // he answered a note in words but never touched the file: one reminder
                    if noteOpen && !nudged {
                        nudged = true
                        agentLog("ended with a note unapplied — one nudge")
                        messages.append(["role": "user", "content": [["type": "text", "text": Self.nudge]]])
                        phase = .thinking
                        continue
                    }
                    finish(recap: recap, prompt: prompt)
                    return
                }
                if turn.stopReason == "max_tokens" { break }
            }
            finish(recap: recap.isEmpty ? "ran out of steps. it's something though." : recap, prompt: prompt)
        } catch is CancellationError {
            return
        } catch let e as URLError where e.code == .cancelled {
            return
        } catch {
            guard !Task.isCancelled else { return }
            agentLog("build failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
            setCaption("the server said no 💀", speak: true)
            subtitle = error.localizedDescription
            game.bugs(3)
        }
    }

    private static let nudge = "[app]: the user's note above is still open. If it asks for a change, make it now (edit_file or write_file) and run_app, then your one-line recap. If it needs no change, just finish with the recap."

    /// Queued notes belong with the user's last message (after its tool results);
    /// if the last message is Splat's own, they start a new one.
    private static func append(_ blocks: [[String: Any]], toLastUserMessageOf messages: inout [[String: Any]]) {
        guard !blocks.isEmpty else { return }
        if var last = messages.last, last["role"] as? String == "user" {
            var content = (last["content"] as? [[String: Any]])
                ?? [["type": "text", "text": last["content"] as? String ?? ""]]
            content += blocks
            last["content"] = content
            messages[messages.count - 1] = last
        } else {
            messages.append(["role": "user", "content": blocks])
        }
    }

    private static func isTransient(_ e: Error) -> Bool {
        if let u = e as? URLError { return u.code != .cancelled }
        if let a = e as? SurfAPIError { return a.transient }
        return false
    }

    /// The build as it happened, in the console (`[agent] +12.3s …`).
    private func agentLog(_ line: String) {
        print(String(format: "[agent] +%.1fs %@", Date().timeIntervalSince(buildStart), line))
    }

    /// The queued notes as text blocks for the next user message.
    private func takeNotes() -> [[String: Any]] {
        let notes = queue
        queue = []
        guard !notes.isEmpty else { return [] }
        for n in notes {
            delivered.append(n.text)
            if let i = feed.firstIndex(where: { $0.noteID == n.id }) { feed[i].kind = .you(delivered: true) }
        }
        let heard = notes.map(\.text).joined(separator: " + ")
        agentLog("notes in: \(heard)")
        setCaption("👂 \(shortPrompt(heard))", speak: false, filler: true)
        return notes.map { ["type": "text", "text": "[user, mid-build]: \($0.text)"] }
    }

    private func log(_ kind: FeedItem.Kind, _ text: String, note: UUID? = nil) {
        feed.append(FeedItem(kind: kind, text: text, noteID: note))
        if feed.count > 80 { feed.removeFirst(feed.count - 80) }
    }

    private func finish(recap: String, prompt: String) {
        agentLog("done: \(shortPrompt(recap)) — \(outputTokens) tok, \(lineCount(html)) lines")
        phase = .done
        project.builds += 1
        project.prompts.append(prompt)
        project.prompts += delivered
        project.recap = recap
        project.tokens += outputTokens
        project.updated = .now
        store.update(project)
        store.addTokens(outputTokens)
        liveCode = ""
        isPatch = false
        previewVersion += 1
        stageTab = .app
        stagePinned = false
        game.celebrate()
        showCutaway(.absolutelyRight, force: true)
        subtitle = recap
        log(.done, recap)
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            setCaption(recap, speak: true)
        }
    }


    // MARK: the remote engine — Claude Code on the mini

    /// Start (or queue on) the agent server, then follow its event feed.
    private func runRemote(_ prompt: String) async {
        lastPrompt = prompt
        phase = .thinking
        outputTokens = 0
        inputTokens = 0
        lastBugs = 0
        steps = 0
        usedFillers = []
        shownCutaways = []
        delivered = []
        subtitle = ""
        liveCode = ""
        isPatch = false
        inputSeen = [:]
        buildStart = .now
        if !stagePinned { stageTab = .code }
        setCaption(project.builds == 0 ? "so it's \(clockString()). new app just dropped" : "they said: \(shortPrompt(prompt))", speak: true)
        agentLog("build on the mini: \(shortPrompt(prompt)) → \(AgentAPI.base().host ?? "?")")
        let filler = Task { await fillerLoop() }
        defer { filler.cancel() }
        do {
            let (seq, _) = try await AgentAPI.state(project.id)
            lastSeq = seq
            if try await AgentAPI.prompt(project.id, text: prompt) {
                agentLog("the mini was still building; the prompt went in as a note")
            }
        } catch {
            guard !Task.isCancelled else { return }
            failRemote(error.localizedDescription)
            return
        }
        await followRemote()
    }

    /// A build that kept running on the mini while nobody watched (the app was
    /// closed, or on another screen): pick it up where it is.
    func attach() {
        guard remote, !building, task == nil else { return }
        task = Task {
            guard let r = try? await AgentAPI.state(project.id), r.state.running else { task = nil; return }
            phase = .thinking
            lastSeq = max(0, r.seq - 60)
            buildStart = .now
            agentLog("attached to a running build at seq \(r.seq)")
            let filler = Task { await fillerLoop() }
            defer { filler.cancel() }
            await followRemote()
        }
    }

    /// Long-poll the server's events until the build is idle.
    private func followRemote() async {
        var failures = 0
        var recap = ""
        while !Task.isCancelled {
            do {
                let poll = try await AgentAPI.events(project.id, after: lastSeq, wait: 20)
                failures = 0
                lastSeq = poll.seq
                var idle = false
                for e in poll.events {
                    if let r = apply(e) { recap = r }
                    if e.type == "idle" { idle = true }
                    if e.type == "error" { return }
                }
                if idle || (!poll.state.running && poll.events.isEmpty) {
                    finishRemote(recap: recap.isEmpty ? (poll.state.recap ?? "it's live. go look.") : recap, state: poll.state)
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                failures += 1
                agentLog("poll failed (\(failures)): \(error.localizedDescription)")
                if failures >= 6 { failRemote("lost the mini: \(error.localizedDescription)"); return }
                setCaption("mini's not answering. retrying 🔁", speak: false, filler: true)
                try? await Task.sleep(for: .seconds(min(10, Double(failures) * 2)))
            }
        }
    }

    private func finishRemote(recap: String, state: AgentAPI.State) {
        if let u = state.deployUrl, let url = URL(string: u) {
            project.siteURL = u
            siteURL = url
        }
        task = nil
        finish(recap: recap, prompt: lastPrompt)
        // deployed = published: the gallery gets it (or the update) without a tap, when signed in
        if let u = state.deployUrl, SurfAccount.shared.signedIn {
            let p = project
            Task {
                do {
                    let app = try await SurfAccount.shared.publish(project: p, html: "", siteURL: u)
                    setRemoteSlug(app.slug)
                    agentLog("in the gallery: \(app.url)")
                    log(.clean, "in the gallery")
                } catch {
                    agentLog("gallery publish failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func failRemote(_ message: String) {
        agentLog("build on the mini failed: \(message)")
        phase = .failed(message)
        setCaption("the mini said no 💀", speak: true)
        subtitle = message
        game.bugs(3)
        task = nil
    }

    /// One server event → the same screen state the local loop drives. Returns a recap when the event carries one.
    private func apply(_ e: AgentAPI.Event) -> String? {
        let d = e.data
        switch e.type {
        case "text":
            let delta = d["delta"] as? String ?? ""
            count(delta)
            subtitle = String((subtitle + delta).suffix(220))
        case "say":
            let text = d["text"] as? String ?? ""
            let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("DEPLOYED:") && !$0.hasPrefix("NAME:") }.last ?? ""
            if !line.isEmpty {
                setCaption(line, speak: true)
                log(.splat(tool: "say"), line)
            }
            subtitle = ""
        case "name":
            if let t = d["title"] as? String, !t.isEmpty { project.title = t }
            if let em = d["emoji"] as? String, !em.isEmpty { project.emoji = String(em.prefix(2)) }
            store.update(project)
        case "tool_start":
            let name = d["name"] as? String ?? ""
            game.toolTrain(name)
            switch name {
            case "Write", "NotebookEdit":
                phase = .writing; liveCode = ""; isPatch = false
                if !stagePinned { stageTab = .code }
            case "Edit", "MultiEdit":
                phase = .editing; isPatch = true; patchOld = ""; patchNew = ""
                if !stagePinned { stageTab = .code }
            case "Read", "Glob", "Grep": phase = .reading
            case "Bash": phase = .running
            default: phase = .thinking
            }
        case "tool_input":
            let id = d["id"] as? String ?? ""
            let name = d["name"] as? String ?? ""
            let json = d["json"] as? String ?? ""
            let seen = inputSeen[id] ?? 0
            if json.count > seen { count(chars: json.count - seen); inputSeen[id] = json.count }
            switch name {
            case "Write":
                if let c = PartialJSON.string("content", in: json) { liveCode = c }
                if let f = PartialJSON.field2("file_path", in: json), f.1 { codePath = (f.0 as NSString).lastPathComponent }
            case "Edit":
                patchOld = PartialJSON.string("old_string", in: json) ?? ""
                patchNew = PartialJSON.string("new_string", in: json) ?? ""
            case "Bash":
                if let c = PartialJSON.string("command", in: json) { subtitle = "$ " + String(c.suffix(200)) }
            default: break
            }
        case "tool_call":
            let name = d["name"] as? String ?? ""
            log(.splat(tool: name), Self.describe(name, d["input"] as? [String: Any] ?? [:]))
        case "tool_result":
            if !(d["ok"] as? Bool ?? true) {
                lastBugs += 1
                game.bugs(1)
                log(.bug, String((d["summary"] as? String ?? "error").replacingOccurrences(of: "\n", with: " ").prefix(80)))
                showCutaway(.hallucinello, force: true)
            }
            phase = .thinking
        case "file":
            if let c = d["content"] as? String {
                remoteCode = c
                liveCode = c
                codePath = ((d["path"] as? String ?? "") as NSString).lastPathComponent
            }
        case "deployed":
            if let u = d["url"] as? String, let url = URL(string: u) {
                siteURL = url
                project.siteURL = u
                store.update(project)
                previewVersion += 1
                if !stagePinned { stageTab = .app }
                log(.clean, "live at \(url.host ?? u)")
            }
        case "note_in":
            let text = d["text"] as? String ?? ""
            if let i = queue.firstIndex(where: { $0.text == text }) {
                let n = queue.remove(at: i)
                delivered.append(n.text)
                if let f = feed.firstIndex(where: { $0.noteID == n.id }) { feed[f].kind = .you(delivered: true) }
            }
            setCaption("👂 \(shortPrompt(text))", speak: false, filler: true)
        case "turn_end":
            if d["ok"] as? Bool ?? false, let r = d["recap"] as? String, !r.isEmpty { return r }
        case "error":
            failRemote(d["message"] as? String ?? "error")
        default:
            break
        }
        return nil
    }

    private static func describe(_ name: String, _ input: [String: Any]) -> String {
        let file = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
        switch name {
        case "Write": return "wrote \(file)"
        case "Edit", "MultiEdit": return "patched \(file)"
        case "Read": return "read \(file)"
        case "Bash": return "$ " + String((input["command"] as? String ?? "").prefix(60))
        case "Glob", "Grep": return "searched \(input["pattern"] as? String ?? "")"
        default: return name.lowercased()
        }
    }

    // MARK: one streamed model call

    private struct ToolCall { let id: String; let name: String; let input: [String: Any]?; let raw: String }
    private struct Turn { var content: [[String: Any]]; var stopReason: String; var toolCalls: [ToolCall]; var text: String }

    private final class Block {
        var type = ""
        var text = ""
        var thinking = ""
        var signature = ""
        var data = ""
        var id = ""
        var name = ""
        var json = ""
        var spokenCaption = false
    }

    private func callModel(_ messages: [[String: Any]]) async throws -> Turn {
        var blocks: [Int: Block] = [:]
        var stopReason = "end_turn"
        var lastUI = Date.distantPast

        for try await ev in SurfAPI.stream(messages: messages) {
            switch ev {
            case let .messageStart(input, cached):
                inputTokens = input + cached
                if inputTokens > 30_000 { showCutaway(.contextino) }
            case let .blockStart(i, raw):
                let b = Block()
                b.type = raw["type"] as? String ?? ""
                b.id = raw["id"] as? String ?? ""
                b.name = raw["name"] as? String ?? ""
                b.data = raw["data"] as? String ?? ""
                blocks[i] = b
                if b.type == "tool_use" { toolStarted(b.name) }
            case let .textDelta(i, t):
                blocks[i]?.text += t
                count(t)
                subtitle = blocks[i]?.text ?? subtitle
            case let .thinkingDelta(i, t):
                blocks[i]?.thinking += t
                count(t)
                if let th = blocks[i]?.thinking, !th.trimmingCharacters(in: .whitespaces).isEmpty { subtitle = th }
            case let .signatureDelta(i, s):
                blocks[i]?.signature += s
            case let .inputJSONDelta(i, p):
                guard let b = blocks[i] else { break }
                b.json += p
                count(p)
                if Date().timeIntervalSince(lastUI) > 0.08 {
                    lastUI = Date()
                    toolStreaming(b)
                }
            case let .blockStop(i):
                if let b = blocks[i], b.type == "tool_use" { toolStreaming(b) }
            case let .messageDelta(reason, out):
                if let reason { stopReason = reason }
                if out > 0 { outputTokens = max(outputTokens, steps + out) }
            case .messageStop:
                break
            }
        }
        try Task.checkCancellation()
        steps = outputTokens

        var content: [[String: Any]] = []
        var calls: [ToolCall] = []
        var text = ""
        for i in blocks.keys.sorted() {
            guard let b = blocks[i] else { continue }
            switch b.type {
            case "text":
                if !b.text.isEmpty { content.append(["type": "text", "text": b.text]) }
                text += b.text
            case "thinking":
                content.append(["type": "thinking", "thinking": b.thinking, "signature": b.signature])
            case "redacted_thinking":
                content.append(["type": "redacted_thinking", "data": b.data])
            case "tool_use":
                let input = (try? JSONSerialization.jsonObject(with: Data((b.json.isEmpty ? "{}" : b.json).utf8))) as? [String: Any]
                content.append(["type": "tool_use", "id": b.id, "name": b.name, "input": input ?? [:]])
                calls.append(ToolCall(id: b.id, name: b.name, input: input, raw: b.json))
            default:
                break
            }
        }
        return Turn(content: content, stopReason: stopReason, toolCalls: calls,
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Streamed characters → an estimate of tokens → coins on the track.
    private var tokenCarry = 0.0
    private func count(_ s: String) { count(chars: s.count) }
    private func count(chars: Int) {
        guard chars > 0 else { return }
        let t = Double(chars) / 3.6
        game.feedTokens(t)
        tokenCarry += t
        if tokenCarry >= 1 {
            outputTokens += Int(tokenCarry)
            tokenCarry -= Double(Int(tokenCarry))
        }
        if outputTokens > 1500 { showCutaway(.tokenur) }
    }

    private func toolStarted(_ name: String) {
        game.toolTrain(name)
        switch name {
        case "write_file":
            phase = .writing
            liveCode = ""
            isPatch = false
            if !stagePinned { stageTab = .code }
        case "edit_file":
            phase = .editing
            isPatch = true
            patchOld = ""
            patchNew = ""
            if !stagePinned { stageTab = .code }
        case "read_file":
            phase = .reading
            showCutaway(.contextino)
        case "run_app":
            phase = .running
        default:
            break
        }
    }

    private func toolStreaming(_ b: Block) {
        if let (cap, done) = PartialJSON.field2("caption", in: b.json), !cap.isEmpty {
            if cap != caption { setCaption(cap, speak: false, bump: !captionStarts(cap)) }
            if done && !b.spokenCaption {
                b.spokenCaption = true
                narrator.say(cap)
                log(.splat(tool: b.name), cap)
            }
        }
        switch b.name {
        case "write_file":
            if let c = PartialJSON.string("content", in: b.json) { liveCode = c }
            if let t = PartialJSON.field2("app_title", in: b.json), t.1, project.title != t.0 {
                project.title = t.0
                if let em = PartialJSON.field2("app_emoji", in: b.json), em.1 { project.emoji = em.0 }
            }
        case "edit_file":
            patchOld = PartialJSON.string("old_string", in: b.json) ?? ""
            patchNew = PartialJSON.string("new_string", in: b.json) ?? ""
        default:
            break
        }
    }

    /// A caption that is still being typed shouldn't restart the animation per letter.
    private func captionStarts(_ c: String) -> Bool { !caption.isEmpty && c.hasPrefix(caption) && !captionIsFiller }

    // MARK: tools

    private func execute(_ call: ToolCall) async -> [String: Any] {
        let r = await perform(call)
        let failed = r["is_error"] as? Bool == true
        var summary = "ok"
        if let t = r["content"] as? String { summary = t }
        else if let parts = r["content"] as? [[String: Any]], let t = parts.first?["text"] as? String { summary = t }
        agentLog("  \(call.name)\(failed ? " ✗" : "") → \(summary.replacingOccurrences(of: "\n", with: " ").prefix(100))")
        return r
    }

    private func perform(_ call: ToolCall) async -> [String: Any] {
        func result(_ text: String, error: Bool = false) -> [String: Any] {
            var r: [String: Any] = ["type": "tool_result", "tool_use_id": call.id, "content": text]
            if error { r["is_error"] = true }
            return r
        }
        guard let input = call.input else {
            return result("{\"INVALID_JSON\": \(String(call.raw.prefix(300)).debugDescription)}", error: true)
        }
        switch call.name {
        case "write_file":
            guard let content = input["content"] as? String, !content.isEmpty else {
                return result("content is required", error: true)
            }
            html = content
            store.saveHTML(content, for: project.id)
            if let t = input["app_title"] as? String, !t.isEmpty { project.title = t }
            if let e = input["app_emoji"] as? String, !e.isEmpty { project.emoji = String(e.prefix(2)) }
            project.updated = .now
            store.update(project)
            liveCode = content
            return result("Wrote index.html (\(lineCount(content)) lines).")

        case "edit_file":
            guard let old = input["old_string"] as? String, let new = input["new_string"] as? String, !old.isEmpty else {
                return result("old_string and new_string are required", error: true)
            }
            let n = html.components(separatedBy: old).count - 1
            if n == 0 { return result("old_string not found in index.html. Use read_file to see the current text.", error: true) }
            if n > 1 { return result("old_string found \(n) times. Include more surrounding lines to make it unique.", error: true) }
            if let r = html.range(of: old) { html.replaceSubrange(r, with: new) }
            store.saveHTML(html, for: project.id)
            project.updated = .now
            store.update(project)
            return result("Edited index.html (now \(lineCount(html)) lines).")

        case "read_file":
            let lines = html.components(separatedBy: "\n")
            let start = max(1, input["start_line"] as? Int ?? 1)
            let end = min(lines.count, input["end_line"] as? Int ?? lines.count, start + 1199)
            guard start <= end else { return result("index.html has \(lines.count) lines.") }
            let body = (start...end).map { "\($0)\t\(lines[$0 - 1])" }.joined(separator: "\n")
            return result("index.html lines \(start)-\(end) of \(lines.count):\n\(body)")

        case "run_app":
            guard !html.isEmpty else { return result("There is no index.html yet. Write it first.", error: true) }
            let r = await AppRunner.shared.run(html: html)
            lastBugs = r.errors.count
            previewVersion += 1
            if !stagePinned { stageTab = .app }
            log(r.errors.isEmpty ? .clean : .bug, r.errors.isEmpty ? "runs clean" : "\(r.errors.count) bug\(r.errors.count == 1 ? "" : "s")")
            if !r.errors.isEmpty {
                game.bugs(r.errors.count)
                showCutaway(.hallucinello, force: true)
            }
            var text = r.errors.isEmpty ? "No errors." : "\(r.errors.count) error(s):\n" + r.errors.map { "- \($0)" }.joined(separator: "\n")
            if !r.notes.isEmpty { text += "\n\nPage: " + r.notes.prefix(6).joined(separator: "\n") }
            var content: [[String: Any]] = [["type": "text", "text": text]]
            if let jpeg = r.jpeg {
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                           "data": jpeg.base64EncodedString()]])
            }
            return ["type": "tool_result", "tool_use_id": call.id, "content": content]

        default:
            return result("unknown tool \(call.name)", error: true)
        }
    }

    // MARK: first message

    private func firstMessage(_ prompt: String) -> String {
        if html.isEmpty { return "Build this: \(prompt)" }
        let earlier = project.prompts.suffix(8).map { "- \($0)" }.joined(separator: "\n")
        return """
        My app "\(project.title)" \(project.emoji). Current index.html:

        <file name="index.html">
        \(html)
        </file>

        \(earlier.isEmpty ? "" : "Earlier requests, oldest first:\n\(earlier)\n\n")New request: \(prompt)
        """
    }

    // MARK: captions + cutaways

    private func setCaption(_ text: String, speak: Bool, bump: Bool = true, filler: Bool = false) {
        caption = text
        captionIsFiller = filler
        if bump { captionID += 1 }
        lastCaptionAt = .now
        if speak { narrator.say(text) }
    }

    private static let fillers = [
        "let him cook 🍳", "thinking really hard", "big brain time 🧠", "tok tok tok",
        "consulting the vibes", "hold my tokens", "no thoughts. just code", "one sec. lock in",
        "reading the prompt again", "it's giving… almost", "pixel by pixel",
    ]

    /// Something on screen while the model thinks silently.
    private func fillerLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(0.5))
            guard phase == .thinking, Date().timeIntervalSince(lastCaptionAt) > 4 else { continue }
            let options = Self.fillers.filter { !usedFillers.contains($0) }
            guard let pick = (options.isEmpty ? Self.fillers : options).randomElement() else { continue }
            usedFillers.insert(pick)
            setCaption(pick, speak: false, filler: true)
        }
    }

    private func showCutaway(_ c: Cutaway, force: Bool = false) {
        guard force || !shownCutaways.contains(c) else { return }
        shownCutaways.insert(c)
        cutaway = c
        Task {
            try? await Task.sleep(for: .seconds(c == .absolutelyRight ? 2.2 : 1.8))
            if cutaway == c { cutaway = nil }
        }
    }

    private func clockString() -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        return f.string(from: .now).lowercased()
    }

    private func shortPrompt(_ p: String) -> String {
        let words = p.split(separator: " ").prefix(6).joined(separator: " ")
        return p.split(separator: " ").count > 6 ? words + "…" : words
    }

    private func lineCount(_ s: String) -> Int { s.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
}

/// Reads captions aloud. A new line waits for the current one to finish
/// (only the newest waits; a line older than 5 s is dropped), so Splat never
/// cuts himself off mid-sentence. Held silent while the mic is open.
@MainActor
final class Narrator: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var pending: (text: String, at: Date)?
    var held = false {
        didSet { if held { stop() } }
    }

    override init() {
        super.init()
        synth.delegate = self
    }

    /// The best installed en-US voice (premium or enhanced if downloaded), never a novelty one.
    private static let voice: AVSpeechSynthesisVoice? = {
        let best = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "en-US" && !$0.voiceTraits.contains(.isNoveltyVoice) && $0.quality != .default }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        return best ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    func say(_ text: String) {
        guard !held, !SurfAudio.shared.muted, UserDefaults.standard.object(forKey: "narrator") as? Bool ?? true else { return }
        let clean = text.unicodeScalars.filter { !$0.properties.isEmojiPresentation && $0.properties.generalCategory != .otherSymbol }
        let s = String(String.UnicodeScalarView(clean)).trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        SurfAudio.shared.start()
        if synth.isSpeaking {
            pending = (s, .now)
            return
        }
        speak(s)
    }

    private func speak(_ s: String) {
        let u = AVSpeechUtterance(string: s)
        u.voice = Self.voice
        u.rate = 0.53
        u.pitchMultiplier = 1.15
        synth.speak(u)
    }

    private func next() {
        guard let p = pending else { return }
        pending = nil
        guard !held, Date().timeIntervalSince(p.at) < 5 else { return }
        speak(p.text)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.next() }
    }

    func stop() {
        pending = nil
        synth.stopSpeaking(at: .immediate)
    }
}
