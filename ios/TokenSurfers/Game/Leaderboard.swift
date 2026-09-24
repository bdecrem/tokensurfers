import Foundation
import Observation
import SwiftUI

/// The global leaderboard: every install has a device id and a handle; the
/// board is each device's best run (/api/surf/scores).
struct LeaderRow: Identifiable, Decodable {
    let rank: Int
    let handle: String
    let score: Int
    let coins: Int
    let distance: Int
    let you: Bool
    var id: Int { rank }
}

struct LeaderYou: Decodable {
    let rank: Int
    let best: Int
    let handle: String
}

struct SubmitResult: Decodable {
    let rank: Int
    let best: Int
    let top: Bool
}

@Observable
@MainActor
final class Leaderboard {
    static let shared = Leaderboard()

    private(set) var top: [LeaderRow] = []
    private(set) var you: LeaderYou?
    private(set) var surfers = 0
    private(set) var loading = false
    private(set) var error: String?
    private(set) var loadedAt: Date?
    private(set) var lastSubmit: SubmitResult?

    let deviceID: String
    var handle: String {
        didSet { UserDefaults.standard.set(handle, forKey: "surf.handle") }
    }
    var hasHandle: Bool { !handle.isEmpty }
    /// Best score on this device, kept locally so the card works offline.
    private(set) var localBest: Int {
        didSet { UserDefaults.standard.set(localBest, forKey: "surf.best") }
    }

    private init() {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "surf.device") {
            deviceID = id
        } else {
            let id = UUID().uuidString.lowercased()
            d.set(id, forKey: "surf.device")
            deviceID = id
        }
        handle = d.string(forKey: "surf.handle") ?? ""
        localBest = d.integer(forKey: "surf.best")
    }

    func noteRun(score: Int) {
        if score > localBest { localBest = score }
    }

    private struct Payload: Decodable { let top: [LeaderRow]; let you: LeaderYou?; let surfers: Int }
    private struct Failure: Decodable { let error: String }

    func refresh(force: Bool = false) async {
        if !force, let at = loadedAt, Date().timeIntervalSince(at) < 20 { return }
        loading = true
        defer { loading = false }
        do {
            var comps = URLComponents(url: backendURL().appendingPathComponent("api/surf/scores"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "device", value: deviceID), URLQueryItem(name: "limit", value: "50")]
            var req = URLRequest(url: comps.url!)
            req.timeoutInterval = 15
            req.setValue(Secrets.appKey, forHTTPHeaderField: "x-surf-key")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw SurfAPIError(message: (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "leaderboard unavailable")
            }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            top = payload.top
            you = payload.you
            surfers = payload.surfers
            if let y = payload.you {
                if y.best > localBest { localBest = y.best }
                if handle.isEmpty { handle = y.handle }
            }
            error = nil
            loadedAt = .now
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Posts a finished run. Returns nil (and keeps the run locally) when offline.
    @discardableResult
    func submit(score: Int, coins: Int, distance: Int, mode: String) async -> SubmitResult? {
        noteRun(score: score)
        guard hasHandle, score > 0 else { return nil }
        do {
            var req = URLRequest(url: backendURL().appendingPathComponent("api/surf/scores"))
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.setValue(Secrets.appKey, forHTTPHeaderField: "x-surf-key")
            let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") + "." +
                (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "device": deviceID, "handle": handle, "score": score, "coins": coins,
                "distance": distance, "mode": mode, "version": version,
            ])
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw SurfAPIError(message: (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "could not post the score")
            }
            let result = try JSONDecoder().decode(SubmitResult.self, from: data)
            lastSubmit = result
            error = nil
            loadedAt = nil
            Task { await refresh(force: true) }
            return result
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

// MARK: - screens

/// The full board: top 50, your row pinned if you're below, rename.
struct LeaderboardView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var board = Leaderboard.shared
    @State private var renaming = false

    var body: some View {
        ZStack {
            Sunburst(a: Theme.purple, b: Color(hex: 0x3D2590), rays: 18)
                .ignoresSafeArea()
            Starfield().ignoresSafeArea().opacity(0.6)
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .black)).foregroundStyle(Theme.ink)
                            .frame(width: 38, height: 38).background(Circle().fill(.white))
                    }
                    .buttonStyle(SquishStyle())
                    .accessibilityLabel("Close")
                    Spacer()
                    Button { renaming = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "pencil").font(.system(size: 12, weight: .black))
                            Text(board.hasHandle ? board.handle : "pick a name").font(Theme.black(13))
                        }
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 12).frame(height: 38)
                        .background(Capsule().fill(.white))
                    }
                    .buttonStyle(SquishStyle())
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)

                VStack(spacing: -10) {
                    StrokedText(text: "TOP", font: Theme.anton(40), stroke: 3)
                    StrokedText(text: "SURFERS", font: Theme.anton(48), color: Theme.yellow, stroke: 3.5)
                }
                .padding(.top, 6)
                Text(board.surfers > 0 ? "\(board.surfers.formatted()) surfers worldwide" : " ")
                    .font(Theme.rounded(12.5, .heavy)).foregroundStyle(.white.opacity(0.9))
                    .padding(.bottom, 10)

                ScrollView {
                    VStack(spacing: 8) {
                        if board.top.isEmpty {
                            Text(board.loading ? "loading…" : (board.error ?? "nobody yet. be first."))
                                .font(Theme.rounded(14, .bold)).foregroundStyle(Theme.ink)
                                .padding(16).frame(maxWidth: .infinity).paperCard()
                        }
                        ForEach(board.top) { row in LeaderRowView(row: row) }
                        if let you = board.you, !board.top.contains(where: \.you) {
                            Text("· · ·").font(Theme.black(14)).foregroundStyle(.white.opacity(0.7))
                            LeaderRowView(row: LeaderRow(rank: you.rank, handle: you.handle, score: you.best, coins: 0, distance: 0, you: true))
                        }
                        if !board.hasHandle, board.localBest > 0 {
                            Button { renaming = true } label: {
                                Text("your best is \(board.localBest.formatted()). pick a name to claim a spot →")
                                    .font(Theme.rounded(13.5, .bold)).foregroundStyle(Theme.ink)
                                    .padding(14).frame(maxWidth: .infinity).background(RoundedRectangle(cornerRadius: 16).fill(Theme.yellow))
                            }
                            .buttonStyle(SquishStyle())
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 30)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await board.refresh(force: true) }
            }
        }
        .task { await board.refresh(force: true) }
        .sheet(isPresented: $renaming) { HandleSheet() }
    }
}

struct LeaderRowView: View {
    let row: LeaderRow

    private var medal: String? { ["🥇", "🥈", "🥉"][safe: row.rank - 1] }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let medal {
                    Text(medal).font(.system(size: 24))
                } else {
                    Text("#\(row.rank)").font(Theme.black(13)).foregroundStyle(Theme.ink2).monospacedDigit()
                }
            }
            .frame(width: 44)
            Text(row.handle.isEmpty ? "surfer" : row.handle)
                .font(Theme.black(15)).foregroundStyle(Theme.ink).lineLimit(1)
            if row.you {
                Text("YOU").font(Theme.black(9)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3).background(Capsule().fill(Theme.splat))
            }
            Spacer()
            Text(row.score.formatted()).font(Theme.anton(20)).foregroundStyle(Theme.ink).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(row.you ? Theme.yellow : Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.ink, lineWidth: row.you ? 2 : 1))
    }
}

/// Pick or change the name the world sees.
struct HandleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var board = Leaderboard.shared
    @State private var text = ""
    @FocusState private var focused: Bool
    var onDone: (() -> Void)?

    var body: some View {
        ZStack {
            Sunburst(spin: false).ignoresSafeArea()
            PaperGrain(opacity: 0.09).ignoresSafeArea()
            VStack(spacing: 18) {
                BlobHero(unit: 46, mood: .cool)
                StrokedText(text: "WHO'S SURFING?", font: Theme.anton(34), stroke: 3)
                TextField("your name", text: $text)
                    .font(Theme.heavy(24))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.ink, lineWidth: 2.5))
                    .onChange(of: text) { _, t in if t.count > 16 { text = String(t.prefix(16)) } }
                Text("16 characters. emoji welcome. the whole world sees it.")
                    .font(Theme.rounded(12.5, .bold)).foregroundStyle(.white)
                    .shadow(color: Theme.ink.opacity(0.5), radius: 0, y: 1.5)
                ChunkyButton(title: "CLAIM IT", fill: text.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.ink2.opacity(0.5) : Theme.splat, action: save)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padding(.horizontal, 24)
            }
            .padding(24)
            .frame(maxWidth: 480)
        }
        .onAppear {
            text = board.handle
            focused = true
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        board.handle = t
        dismiss()
        onDone?()
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
