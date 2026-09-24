import SwiftUI

/// The build as a TikTok-live comment stream over the stage: what Splat just
/// did (the captions he spoke), what you told him, and whether he's seen it
/// yet. The last four lines; older ones fade.
struct LiveFeed: View {
    let items: [Studio.FeedItem]

    var body: some View {
        let shown = Array(items.suffix(4))
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                FeedRow(item: item)
                    .opacity(i == shown.count - 1 ? 1 : 0.5 + 0.15 * Double(i))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
        .allowsHitTesting(false)
    }
}

struct FeedRow: View {
    let item: Studio.FeedItem
    var full = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(icon).font(.system(size: 12))
            if isYou {
                Text("you").font(Theme.black(12)).foregroundStyle(Theme.ink.opacity(0.7))
            }
            Text(item.text)
                .font(Theme.rounded(13, .bold))
                .foregroundStyle(isYou ? Theme.ink : .white)
                .lineLimit(full ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            if case .you(let delivered) = item.kind {
                Text(delivered ? "✓ heard" : "next step")
                    .font(Theme.black(10.5))
                    .foregroundStyle(delivered ? Theme.ink : Theme.ink.opacity(0.55))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(isYou ? Theme.yellow : Color.black.opacity(0.62)))
    }

    private var isYou: Bool {
        if case .you = item.kind { return true }
        return false
    }

    private var icon: String {
        switch item.kind {
        case .splat(let tool):
            switch tool {
            case "write_file", "Write", "NotebookEdit": return "✍️"
            case "edit_file", "Edit", "MultiEdit": return "🩹"
            case "read_file", "Read", "Glob", "Grep": return "👀"
            case "run_app", "Bash": return "🧪"
            default: return "🟠"
            }
        case .you(let delivered): return delivered ? "💬" : "⏳"
        case .bug: return "🐞"
        case .clean: return "✅"
        case .done: return "🏁"
        }
    }
}

/// Everything Splat did in this session, from the ••• menu.
struct BuildLog: View {
    let items: [Studio.FeedItem]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { FeedRow(item: $0, full: true) }
                }
                .padding(16)
            }
            .background(Theme.navy.ignoresSafeArea())
            .navigationTitle("What Splat did")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
