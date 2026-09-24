import SwiftUI
import WebKit

// MARK: - the running app

/// The user's app, live. Reloads when `version` changes; each project gets its
/// own origin so localStorage stays per app.
struct PreviewWebView: UIViewRepresentable {
    let html: String
    let version: Int
    let projectID: UUID

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
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
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {
        let key = "\(projectID)-\(version)-\(html.count)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        w.loadHTMLString(html, baseURL: URL(string: "https://\(projectID.uuidString.lowercased().prefix(8)).tokensurfers.app/"))
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: .zero, configuration: config)
        w.isOpaque = false
        w.backgroundColor = .white
        w.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 16.4, *) { w.isInspectable = true }
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {
        let key = "\(url.absoluteString)-\(version)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        w.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30))
    }

    final class Coordinator { var loadedKey = "" }
}

// MARK: - the code screen (the video's 3:00 AM monitor)

struct CodeView: View {
    let code: String
    let streaming: Bool
    var isPatch = false
    var patchOld = ""
    var patchNew = ""

    var body: some View {
        let lines = code.isEmpty ? [] : code.components(separatedBy: "\n")
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
                                        Text(Syntax.color(lines[i]))
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
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04)],
                                         startPoint: .top, endPoint: .bottom))
                }
            }
            .padding(.top, 56)
        }
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

    private func patchBlock(_ text: String, color: Color, sign: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(text.components(separatedBy: "\n").prefix(80).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(sign).font(Theme.mono(12, .bold)).foregroundStyle(color)
                    Text(line.isEmpty ? " " : line).font(Theme.mono(12)).foregroundStyle(.white.opacity(0.92))
                        .strikethrough(sign == "−", color: color.opacity(0.7))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.5), lineWidth: 1))
    }
}

/// A small tokenizer for HTML/CSS/JS lines: good enough to read like an editor.
enum Syntax {
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

struct Starfield: View {
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                var rng = SeededRandom(seed: 5)
                let t = tl.date.timeIntervalSinceReferenceDate
                for i in 0..<40 {
                    let x = rng.unit() * size.width, y = rng.unit() * size.height
                    let s = 4 + rng.unit() * 6 + sin(t * 3 + Double(i)) * 1.5
                    ctx.draw(Text("★").font(.system(size: s)).foregroundStyle(Theme.yellow), at: CGPoint(x: x, y: y))
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
