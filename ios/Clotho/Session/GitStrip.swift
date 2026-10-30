import ClothoKit
import SwiftUI

/// A pane in a git work tree (clothod's `git`, 0.1.23) gets a thin strip at the bottom of the terminal:
/// "repo · branch · worktree", then its pull request, "PR #42 open", which opens on GitHub. Never in workspace
/// or tab names (the user's rule, 2026-10-29). Outside a repo, or against an older daemon, there's no strip.
struct GitStrip: View {
    let git: PaneGit
    @Environment(\.openURL) private var openURL

    static let height: CGFloat = 24

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(git.summary)
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .accessibilityIdentifier("gitSummary")
            Spacer(minLength: 8)
            if let pr = git.pr {
                let url = Self.url(of: pr)
                Button { url.map { openURL($0) } } label: { Self.label(of: pr) }
                    .buttonStyle(.plain)
                    .disabled(url == nil)
                    .layoutPriority(1)
                    .accessibilityLabel(["Pull request \(pr.number)", Self.describe(pr.state).word, pr.title]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
                    .accessibilityIdentifier("gitPullRequest")
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gitStrip")
    }

    /// "PR #42" in the accent colour, then the state in GitHub's.
    static func label(of pr: PaneGit.PullRequest) -> Text {
        let (word, color) = describe(pr.state)
        let number = Text("PR #\(pr.number)").fontWeight(.medium).foregroundColor(.accentColor)
        return word.isEmpty ? number : number + Text("  \(word)").foregroundColor(color)
    }

    /// The state's word and colour, as GitHub shows them.
    static func describe(_ state: PaneGit.PullRequest.State?) -> (word: String, color: Color) {
        switch state {
        case .open: return ("open", .green)
        case .draft: return ("draft", .secondary)
        case .merged: return ("merged", .purple)
        case .closed: return ("closed", .red)
        case nil: return ("", .secondary)
        }
    }

    /// Only GitHub pages open (the daemon only sends those).
    static func url(of pr: PaneGit.PullRequest) -> URL? {
        guard let text = pr.url, let url = URL(string: text), url.scheme == "https", url.host == "github.com" else { return nil }
        return url
    }
}
