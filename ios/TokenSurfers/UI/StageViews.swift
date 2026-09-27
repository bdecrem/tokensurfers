import SwiftUI
import WebKit

// MARK: - the running app

/// The user's app, live. Reloads when `version` changes; each project gets its
/// own origin so localStorage stays per app.
struct PreviewWebView: UIViewRepresentable {
    let html: String
    let version: Int
    let projectID: UUID
    /// While the player is surfing, the app is a still (see FreezableWebView).
    var frozen = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> FreezableWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: config)
        w.uiDelegate = context.coordinator
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.scrollView.bounces = false
        if #available(iOS 16.4, *) { w.isInspectable = true }
        return FreezableWebView(web: w)
    }

    func updateUIView(_ v: FreezableWebView, context: Context) {
        let key = "\(projectID)-\(version)-\(html.count)"
        if context.coordinator.loadedKey != key {
            context.coordinator.loadedKey = key
            v.web.loadHTMLString(html, baseURL: URL(string: "https://\(projectID.uuidString.lowercased().prefix(8)).tokensurfers.app/"))
        }
        v.setFrozen(frozen)
    }

    final class Coordinator: NSObject, WKUIDelegate {
        var loadedKey = ""
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(true) }
    }
}

/// The deployed app (Claude Code on the mini built it): a plain web view on
/// the Vercel URL, reloaded past the cache when `version` changes.
struct SiteWebView: UIViewRepresentable {
    let url: URL
    let version: Int
    var frozen = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> FreezableWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: config)
        w.isOpaque = false
        w.backgroundColor = .white
        w.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 16.4, *) { w.isInspectable = true }
        return FreezableWebView(web: w)
    }

    func updateUIView(_ v: FreezableWebView, context: Context) {
        let key = "\(url.absoluteString)-\(version)"
        if context.coordinator.loadedKey != key {
            context.coordinator.loadedKey = key
            v.web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30))
        }
        v.setFrozen(frozen)
    }

    final class Coordinator { var loadedKey = "" }
}

/// A web view that can be swapped for a still of itself. While the player is
/// surfing under a finished app, the app's own animations and repaints were
/// competing with the game for the GPU (15–29 fps on the phone, 2026-09-26);
/// frozen, the web view leaves the window — WebKit stops painting a hidden
/// page — and a snapshot stands in until the stage is tapped.
final class FreezableWebView: UIView {
    let web: WKWebView
    private let snap = UIImageView()
    private(set) var frozen = false

    init(web: WKWebView) {
        self.web = web
        super.init(frame: .zero)
        backgroundColor = .white
        snap.contentMode = .top
        snap.clipsToBounds = true
        snap.isHidden = true
        addSubview(web)
        addSubview(snap)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        web.frame = bounds
        snap.frame = bounds
    }

    func setFrozen(_ f: Bool) {
        guard f != frozen else { return }
        if f, web.isLoading { return }      // a still of a half-loaded page would be blank; stay live until it has loaded
        frozen = f
        if f {
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = false
            web.takeSnapshot(with: config) { [weak self] image, _ in
                guard let self, self.frozen, let image else { return }
                self.snap.image = image
                self.snap.isHidden = false
                self.web.removeFromSuperview()
            }
        } else {
            if web.superview == nil { insertSubview(web, belowSubview: snap); web.frame = bounds }
            snap.isHidden = true
            snap.image = nil
        }
    }
}

// MARK: - the code screen (the video's 3:00 AM monitor)

struct CodeView: View, Equatable {
    let code: String
    let streaming: Bool
    var isPatch = false
    var patchOld = ""
    var patchNew = ""

    /// The last split, so an unchanged file isn't re-split on every parent update.
    nonisolated(unsafe) private static var lastCode = ""
    nonisolated(unsafe) private static var lastLines: [String] = []
    private static func lines(of code: String) -> [String] {
        if code == lastCode { return lastLines }
        lastCode = code
        lastLines = code.isEmpty ? [] : code.components(separatedBy: "\n")
        return lastLines
    }

    var body: some View {
        let lines = Self.lines(of: code)
        ZStack(alignment: .top) {
            Theme.navy
            PaperGrain(opacity: 0.05)
            VStack(spacing: 6) {
                header(lines.count)
                if isPatch {
                    patchView
                } else if lines.isEmpty {
                    Text(streaming ? "warming up the keyboard…" : "no code yet")
                        .font(Theme.mono(14)).foregroundStyle(Theme.lavender.opacity(0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if streaming {
                    // While the file streams the view is pinned to its end anyway, so
                    // only the lines that fit are laid out, as ONE text: a growing
                    // LazyVStack with a scrollTo per tick re-measured the whole file
                    // four times a second (the split-screen stutter, 2026-09-26).
                    GeometryReader { g in
                        let fit = Int(g.size.height / 15.5) + 1
                        Text(Self.tail(lines, fit))
                            .font(Theme.mono(12.5))
                            .lineSpacing(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(width: g.size.width, height: g.size.height, alignment: .bottomLeading)
                            .clipped()
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 8)
                    .overlay(alignment: .top) { fadeTop }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(lines.indices, id: \.self) { i in
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text("\(i + 1)")
                                            .font(Theme.mono(11))
                                            .foregroundStyle(Theme.lavender.opacity(0.35))
                                            .frame(width: 34, alignment: .trailing)
                                        Text(Syntax.colored(lines[i]))
                                            .font(Theme.mono(12.5))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .id(i)
                                }
                                Color.clear.frame(height: 90).id("end")
                            }
                            .padding(.trailing, 8)
                            .padding(.top, 4)
                        }
                        .onChange(of: lines.count) { _, _ in
                            if streaming { proxy.scrollTo("end", anchor: .bottom) }
                        }
                    }
                    .overlay(alignment: .top) { fadeTop }
                }
            }
            .padding(.top, 56)
        }
    }

    /// The top edge fades into the monitor: a gradient painted over it, not a
    /// mask (a mask re-renders the whole stage offscreen on every frame).
    private var fadeTop: some View {
        LinearGradient(colors: [Theme.navy, Theme.navy.opacity(0)], startPoint: .top, endPoint: .bottom)
            .frame(height: 16)
            .allowsHitTesting(false)
    }

    /// The last `fit` lines, numbered, as one attributed string (per-line colouring is cached).
    private static func tail(_ lines: [String], _ fit: Int) -> AttributedString {
        let start = max(0, lines.count - fit)
        var out = AttributedString()
        let width = String(lines.count).count
        for i in start..<lines.count {
            var num = AttributedString(String(repeating: " ", count: max(0, width - String(i + 1).count)) + "\(i + 1)  ")
            num.foregroundColor = Theme.lavender.opacity(0.35)
            out += num
            out += Syntax.colored(lines[i])
            if i < lines.count - 1 { out += AttributedString("\n") }
        }
        return out
    }

    private func header(_ n: Int) -> some View {
        HStack {
            StrokedText(text: "\(n.formatted()) lines", font: Theme.anton(24), color: Theme.yellow, stroke: 2)
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                Text(tl.date.formatted(date: .omitted, time: .shortened).uppercased())
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xFF4B4B))
                    .shadow(color: Color(hex: 0xFF4B4B).opacity(0.8), radius: 6)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1A0A10)))
            }
        }
        .padding(.horizontal, 14)
        .allowsHitTesting(false)
    }

    private var patchView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("PATCHING").font(Theme.black(13)).foregroundStyle(Theme.yellow)
                if !patchOld.isEmpty {
                    patchBlock(patchOld, color: Theme.red, sign: "−")
                }
                patchBlock(patchNew.isEmpty ? "…" : patchNew, color: Theme.mint, sign: "+")
            }
            .padding(14)
        }
    }

    /// One text per block (a streaming new_string used to rebuild up to 80 rows per tick).
    private func patchBlock(_ text: String, color: Color, sign: String) -> some View {
        var out = AttributedString()
        for (k, line) in text.components(separatedBy: "\n").prefix(80).enumerated() {
            var s = AttributedString(sign + " ")
            s.foregroundColor = color
            s.font = Theme.mono(12, .bold)
            var l = AttributedString(line.isEmpty ? " " : line)
            l.foregroundColor = .white.opacity(0.92)
            if sign == "−" { l.strikethroughStyle = Text.LineStyle(pattern: .solid, color: color.opacity(0.7)) }
            if k > 0 { out += AttributedString("\n") }
            out += s + l
        }
        return Text(out)
            .font(Theme.mono(12))
            .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.5), lineWidth: 1))
    }
}

/// A small tokenizer for HTML/CSS/JS lines: good enough to read like an editor.
enum Syntax {
    /// Coloured lines by their text: a streaming file repeats every line but
    /// the last few on each update, so the colouring runs once per line.
    nonisolated(unsafe) private static var cache: [String: AttributedString] = [:]
    static func colored(_ line: String) -> AttributedString {
        if let hit = cache[line] { return hit }
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        let v = color(line)
        cache[line] = v
        return v
    }
    static let keywords: Set<String> = ["let", "const", "var", "function", "return", "if", "else", "for", "while",
                                        "class", "new", "true", "false", "null", "this", "import", "export", "async",
                                        "await", "switch", "case", "break", "of", "in", "typeof", "undefined", "try", "catch"]
    static let plain = Color(hex: 0xE9E6FF)
    static let kw = Color(hex: 0xC792EA)
    static let str = Color(hex: 0xA5E07A)
    static let num = Color(hex: 0xF9A870)
    static let tag = Color(hex: 0xFF8FB1)
    static let comment = Color(hex: 0x6E6A99)
    static let ident = Color(hex: 0xFFD580)

    static func color(_ line: String) -> AttributedString {
        var out = AttributedString()
        let chars = Array(line)
        var i = 0
        func emit(_ s: String, _ c: Color) {
            var a = AttributedString(s)
            a.foregroundColor = c
            out += a
        }
        if chars.count > 400 { emit(String(chars.prefix(400)) + "…", plain); return out }
        while i < chars.count {
            let c = chars[i]
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                emit(String(chars[i...]), comment); break
            }
            if c == "<" && i + 1 < chars.count && (chars[i + 1].isLetter || chars[i + 1] == "/" || chars[i + 1] == "!") {
                var j = i + 1
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "/" || chars[j] == "!" || chars[j] == "-") { j += 1 }
                emit(String(chars[i..<j]), tag); i = j; continue
            }
            if c == "\"" || c == "'" || c == "`" {
                var j = i + 1
                while j < chars.count && chars[j] != c { if chars[j] == "\\" { j += 1 }; j += 1 }
                j = min(j + 1, chars.count)
                emit(String(chars[i..<j]), str); i = j; continue
            }
            if c.isNumber {
                var j = i
                while j < chars.count && (chars[j].isNumber || chars[j] == ".") { j += 1 }
                emit(String(chars[i..<j]), num); i = j; continue
            }
            if c.isLetter || c == "_" || c == "$" {
                var j = i
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "$" || chars[j] == "-") { j += 1 }
                let word = String(chars[i..<j])
                let next = j < chars.count ? chars[j] : " "
                emit(word, keywords.contains(word) ? kw : (next == "(" ? ident : plain))
                i = j; continue
            }
            var j = i
            while j < chars.count, !(chars[j].isLetter || chars[j].isNumber || "\"'`<_/$".contains(chars[j])) { j += 1 }
            if j == i { j += 1 }
            emit(String(chars[i..<j]), plain.opacity(0.75)); i = j
        }
        return out
    }
}

// MARK: - cutaways (the character moments)

struct CutawayView: View {
    let cutaway: Studio.Cutaway
    var bugs = 0
    @State private var pop = false

    var body: some View {
        GeometryReader { g in
            let m = min(g.size.width, g.size.height)
            ZStack {
                background
                VStack(spacing: m * 0.02) {
                    titles(m)
                    character(m)
                }
                .padding(.top, 40)
                .scaleEffect(pop ? 1 : 0.6)
                .opacity(pop ? 1 : 0)
            }
        }
        .clipped()
        .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { pop = true } }
    }

    @ViewBuilder private var background: some View {
        switch cutaway {
        case .tokenur:
            ZStack {
                Theme.purple
                Starfield()
            }
        case .contextino:
            LinearGradient(colors: [Color(hex: 0x3F8FD6), Color(hex: 0x6FB8EA), Color(hex: 0x2E6FAF)], startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .bottom) { Color(hex: 0xE3C48F).frame(height: 40) }
        case .hallucinello:
            Sunburst(a: Theme.yellow, b: Color(hex: 0xFFE27A))
        case .absolutelyRight:
            Sunburst(a: Theme.pink, b: Theme.yellow, rays: 18)
        }
        PaperGrain(opacity: 0.1)
    }

    @ViewBuilder private func titles(_ m: CGFloat) -> some View {
        let s = m * 0.13
        switch cutaway {
        case .tokenur:
            VStack(spacing: -s * 0.2) {
                StrokedText(text: "TOK TOK TOK", font: Theme.anton(s), stroke: 3)
                StrokedText(text: "TOKENUR", font: Theme.anton(s * 1.15), color: Theme.yellow, stroke: 3)
            }
        case .contextino:
            VStack(spacing: -s * 0.2) {
                StrokedText(text: "CONTEXTINO", font: Theme.anton(s), stroke: 3)
                StrokedText(text: "WINDOWINI", font: Theme.anton(s * 1.1), color: Theme.yellow, stroke: 3)
            }
        case .hallucinello:
            VStack(spacing: -s * 0.2) {
                StrokedText(text: "HALLUCINELLO", font: Theme.anton(s * 0.85), stroke: 3)
                StrokedText(text: bugs > 0 ? "CONFIDENZO · \(bugs) 🐞" : "CONFIDENZO", font: Theme.anton(s * 0.85), color: Theme.yellow, stroke: 3)
            }
        case .absolutelyRight:
            VStack(spacing: -s * 0.15) {
                StrokedText(text: "YOU'RE ABSOLUTELY", font: Theme.anton(s * 0.8), color: Theme.yellow, stroke: 3)
                StrokedText(text: "RIGHT!", font: Theme.anton(s * 1.2), color: Theme.yellow, stroke: 3)
            }
        }
    }

    @ViewBuilder private func character(_ m: CGFloat) -> some View {
        switch cutaway {
        case .tokenur: Tokenur(size: m * 0.5)
        case .contextino: Contextino(size: m * 0.45)
        case .hallucinello: Hallucinello(size: m * 0.5)
        case .absolutelyRight: BlobHero(unit: m * 0.3, mood: .wow)
        }
    }
}

/// Twinkling stars. Paths, not text glyphs, at 24 fps: the text version at
/// 60 fps was the single biggest CPU cost in the whole app (2026-09-24
/// profile), and it kept running on Home behind an open Studio.
struct Starfield: View {
    var paused = false

    private static let star: Path = {
        var p = Path()
        for i in 0..<10 {
            let a = Double(i) * .pi / 5 - .pi / 2
            let r = i % 2 == 0 ? 1.0 : 0.42
            let pt = CGPoint(x: cos(a) * r, y: sin(a) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: paused)) { tl in
            Canvas { ctx, size in
                var rng = SeededRandom(seed: 5)
                let t = tl.date.timeIntervalSinceReferenceDate
                for i in 0..<40 {
                    let x = rng.unit() * size.width, y = rng.unit() * size.height
                    let s = (4 + rng.unit() * 6 + sin(t * 3 + Double(i)) * 1.5) * 0.55
                    let path = Self.star.applying(CGAffineTransform(translationX: x, y: y).scaledBy(x: s, y: s))
                    ctx.fill(path, with: .color(Theme.yellow))
                }
            }
        }
    }
}

// MARK: - the empty stage

struct EmptyStage: View {
    var body: some View {
        ZStack {
            Sunburst(spin: true)
            PaperGrain(opacity: 0.1)
            VStack(spacing: 16) {
                BlobHero(unit: 70)
                StrokedText(text: "WHAT ARE WE", font: Theme.black(26), stroke: 2.5)
                StrokedText(text: "BUILDING?", font: Theme.black(34), color: Theme.yellow, stroke: 3)
                Text("type it below ↓").font(Theme.rounded(15, .bold)).foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}
