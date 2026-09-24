import SwiftUI

/// The big karaoke caption on the seam between the stage and the game:
/// a caption plays as 1-3 word chunks, one word highlighted yellow.
struct CaptionBand: View {
    let caption: String
    let id: Int
    var size: CGFloat = 34
    var filler = false

    @State private var startedAt = Date()

    var body: some View {
        let chunks = Self.chunks(caption)
        TimelineView(.periodic(from: startedAt, by: 0.1)) { tl in
            let elapsed = tl.date.timeIntervalSince(startedAt)
            // play the chunks, hold the last one a beat, then loop so the whole line stays readable
            let beats = chunks.count + (chunks.count > 1 ? 1 : 0)
            let beat = Int(elapsed / 0.55) % max(beats, 1)
            let idx = min(chunks.count - 1, max(0, beat))
            if !chunks.isEmpty {
                let words = chunks[idx]
                CaptionLine(words: words.map { $0.uppercased() },
                            highlight: Self.highlight(words),
                            size: filler ? size * 0.72 : size)
                    .id("\(id)-\(idx)")
                    .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity), removal: .opacity))
                    .animation(.spring(response: 0.22, dampingFraction: 0.5), value: idx)
                    .padding(.horizontal, 12)
            }
        }
        .onChange(of: id) { _, _ in startedAt = .now }
        .allowsHitTesting(false)
        .accessibilityLabel(caption)
    }

    static func chunks(_ s: String) -> [[String]] {
        let words = s.split(separator: " ").map(String.init)
        var out: [[String]] = []
        var cur: [String] = []
        var len = 0
        for w in words {
            if cur.count == 3 || (len + w.count > 15 && !cur.isEmpty) {
                out.append(cur); cur = []; len = 0
            }
            cur.append(w); len += w.count + 1
            if w.hasSuffix(".") || w.hasSuffix("?") || w.hasSuffix("!") {
                out.append(cur); cur = []; len = 0
            }
        }
        if !cur.isEmpty { out.append(cur) }
        // a trailing lone emoji rides with the words before it
        if out.count > 1, let last = out.last, last.count == 1, last[0].unicodeScalars.allSatisfy({ $0.properties.isEmoji && $0.value > 0x238C }) {
            out.removeLast()
            out[out.count - 1].append(last[0])
        }
        return out
    }

    static func highlight(_ words: [String]) -> Set<Int> {
        let letters = words.map { $0.filter { $0.isLetter || $0.isNumber }.count }
        if words.count == 1 { return letters[0] >= 5 || words[0].contains(where: \.isNumber) ? [0] : [] }
        guard let best = letters.indices.max(by: { letters[$0] < letters[$1] }), letters[best] >= 3 else { return [] }
        return [best]
    }
}

/// The TikTok closed-caption box: what the agent is actually saying.
struct SubtitleBox: View {
    let text: String
    var body: some View {
        if !text.isEmpty {
            Text(Self.tail(text))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.62)))
                .frame(maxWidth: 320, alignment: .leading)
                .allowsHitTesting(false)
        }
    }

    static func tail(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > 110 else { return flat }
        return "…" + flat.suffix(108)
    }
}
