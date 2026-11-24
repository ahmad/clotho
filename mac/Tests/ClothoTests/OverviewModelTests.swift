import ClothoKit
import XCTest
@testable import Clotho

/// The Overview's model: which agents get a card and in which lane, what a card says, the filter, the
/// grid and its arrow-key moves.
@MainActor
final class OverviewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let everything: Set<Hello.Feature> = [.git, .gitChanges, .peek]

    private func entry(_ pane: PaneID, _ state: AgentInfo.State, attention: Bool? = true, needsUser: Bool? = nil,
                       settling: Bool? = nil, muted: Bool? = nil, message: String? = nil, ago: Double? = 120,
                       took: Double? = nil, requests: [PermissionRequest]? = nil, kind: String = "claude",
                       machine: MachineKey = "local", machineName: String = "devbox", workspace: String? = "clotho",
                       tab: String? = "alerts", canMute: Bool = true) -> AgentEntry {
        let since = ago.map { now.timeIntervalSince1970 - $0 }
        var entry = AgentEntry(machine: machine, machineName: machineName, pane: pane,
                               workspace: workspace.map { Workspace(id: 1, name: $0, tabs: []) },
                               tab: Tab(id: TabID(pane + 100), activePane: pane, layout: .pane(pane)), paneTitle: "zsh", tabTitle: tab,
                               info: AgentInfo(kind: kind, state: state, source: "hook", message: message, since: since,
                                               attention: attention, muted: muted,
                                               turnStarted: since.flatMap { since in took.map { since - $0 } },
                                               requests: requests, needsUser: needsUser, settling: settling),
                               canReply: false)
        entry.canMute = canMute
        return entry
    }

    private func source(_ features: Set<Hello.Feature>? = nil, git: [PaneID: PaneGit] = [:], machine: MachineKey = "local") -> OverviewSource {
        OverviewSource(features: [machine: features ?? everything],
                       git: Dictionary(uniqueKeysWithValues: git.map { (PaneKey(machine: machine, pane: $0.key), $0.value) }))
    }

    private func card(_ entry: AgentEntry, _ source: OverviewSource = OverviewSource()) -> OverviewCard {
        OverviewCard(entry, source: source, now: now)!
    }

    private func cards(_ entries: [AgentEntry], _ source: OverviewSource = OverviewSource()) -> [OverviewCard] {
        OverviewModel.cards(OverviewModel.lanes(entries, source: source, now: now))
    }

    // MARK: Lanes

    func testLanesHoldTheMarkedAgentsInScreenOrder() {
        let lanes = OverviewModel.lanes([
            entry(1, .running, attention: nil, ago: 300),
            entry(2, .waiting, ago: 60),
            entry(3, .done, needsUser: false, ago: 500),
            entry(4, .error, ago: 900),
            entry(5, .waiting, ago: 400),
            entry(6, .running, attention: nil, ago: 20),
            entry(7, .done, needsUser: true, ago: 200),
            entry(8, .done, needsUser: false, ago: 30),
        ], now: now)
        XCTAssertEqual(lanes.map(\.lane), [.needsYou, .working, .done])
        XCTAssertEqual(lanes[0].cards.map(\.key.pane), [4, 5, 7, 2], "the longest wait first, the failed one among them")
        XCTAssertEqual(lanes[0].cards.map(\.mark), [.error, .needsYou, .needsYou, .needsYou])
        XCTAssertEqual(lanes[1].cards.map(\.key.pane), [6, 1], "the most recent first")
        XCTAssertEqual(lanes[2].cards.map(\.key.pane), [8, 3])
        XCTAssertTrue(lanes.allSatisfy { lane in lane.cards.allSatisfy { $0.lane == lane.lane } })
    }

    func testAgentsWithNoMarkHaveNoCard() {
        let quiet = [
            entry(1, .waiting, attention: false),
            entry(2, .done, attention: false, needsUser: true),
            entry(3, .done, attention: false, settling: true),
            entry(4, .done, attention: true, needsUser: true, settling: true),
            entry(5, .waiting, muted: true),
            entry(6, .unknown, attention: nil),
        ]
        XCTAssertTrue(OverviewModel.lanes(quiet, now: now).isEmpty)
        for entry in quiet { XCTAssertNil(OverviewCard(entry, now: now), "pane \(entry.pane)") }
    }

    func testEmptyLanesAreLeftOut() {
        let lanes = OverviewModel.lanes([entry(1, .done, needsUser: false), entry(2, .waiting, attention: false)], now: now)
        XCTAssertEqual(lanes.map(\.lane), [.done])
        XCTAssertEqual(lanes[0].cards.map(\.key), [PaneKey(machine: "local", pane: 1)])
        XCTAssertTrue(OverviewModel.lanes([], now: now).isEmpty)
    }

    // MARK: Title

    func testTitleCountsAgentsAndTheirMachines() {
        let six = cards((1...4).map { entry($0, .waiting) } + (5...6).map { entry($0, .running, attention: nil, machine: "m2", machineName: "macbook") })
        XCTAssertEqual(OverviewModel.title(cards: six), "Overview · 6 agents on 2 machines")
        XCTAssertEqual(OverviewModel.title(cards: Array(six.prefix(2))), "Overview · 2 agents on 1 machine")
        XCTAssertEqual(OverviewModel.title(cards: Array(six.prefix(1))), "Overview · 1 agent on 1 machine")
        XCTAssertEqual(OverviewModel.title(cards: []), "Overview · no agents")
    }

    // MARK: A card's text

    func testAgeFollowsTheMarksBuckets() {
        XCTAssertEqual(card(entry(1, .waiting, ago: 150)).age, "2 min")
        XCTAssertEqual(card(entry(1, .error, ago: 150)).age, "2 min")
        XCTAssertEqual(card(entry(1, .running, attention: nil, ago: 30)).age, "<1 min")
        XCTAssertEqual(card(entry(1, .running, attention: nil, ago: 3 * 3600 + 5)).age, "3 h")
        XCTAssertEqual(card(entry(1, .waiting, ago: 2 * 86400 + 5)).age, "2 d")
        XCTAssertEqual(card(entry(1, .waiting, ago: nil)).age, "", "no time from the daemon")
        // The same buckets as the pane header's text.
        for seconds in [0.0, 59, 60, 3599, 3600, 86399, 86400, 400_000] {
            let since = now.timeIntervalSince1970 - seconds
            XCTAssertEqual(OverviewCard.elapsed(since: since, now: now), AgentMark.working.elapsedText(since: since, now: now), "\(seconds) s")
            XCTAssertEqual("waiting " + OverviewCard.elapsed(since: since, now: now)!, AgentMark.needsYou.elapsedText(since: since, now: now))
        }
    }

    func testDoneSaysHowLongAgoAndHowLongItTook() {
        let done = card(entry(1, .done, needsUser: false, ago: 23 * 60, took: 8 * 60))
        XCTAssertEqual(done.age, "23 min ago")
        XCTAssertEqual(done.sub, "devbox · Claude · took 8 min")
        XCTAssertEqual(card(entry(1, .done, needsUser: false, ago: 10)).age, "<1 min ago")
        XCTAssertEqual(card(entry(1, .done, needsUser: false, ago: 10)).sub, "devbox · Claude", "no turn start, no took")
        XCTAssertEqual(card(entry(1, .done, needsUser: false, ago: nil)).age, "")
        // A finished turn that asks is in Needs you: it waits, and says nothing of the turn's length.
        let asks = card(entry(1, .done, needsUser: true, ago: 23 * 60, took: 8 * 60))
        XCTAssertEqual(asks.age, "23 min")
        XCTAssertEqual(asks.sub, "devbox · Claude")
    }

    func testSubLineNamesTheMachineTheAgentAndMuted() {
        XCTAssertEqual(card(entry(1, .waiting)).sub, "devbox · Claude")
        XCTAssertEqual(card(entry(1, .running, attention: nil, kind: "codex", machineName: "macbook")).sub, "macbook · Codex")
        let muted = card(entry(1, .running, muted: true))
        XCTAssertEqual(muted.sub, "devbox · Claude · muted")
        XCTAssertTrue(muted.isMuted)
        XCTAssertEqual(muted.mark, .working)
    }

    func testPermissionAskIsTheMessage() {
        let ask = card(entry(1, .waiting, message: "Claude needs your permission to use Bash",
                             requests: [PermissionRequest(id: "r1", tool: "Bash", summary: "cargo test --workspace"),
                                        PermissionRequest(id: "r2", tool: "Edit", summary: "main.rs")]))
        XCTAssertEqual(ask.message, "Allow Bash: cargo test --workspace")
        XCTAssertEqual(card(entry(1, .done, needsUser: false, message: "All tests pass.")).message, "All tests pass.")
        XCTAssertNil(card(entry(1, .running, attention: nil)).message)
    }

    func testPlaceActionsAndTab() {
        let waiting = card(entry(7, .waiting))
        XCTAssertEqual(waiting.place, "clotho › alerts")
        XCTAssertEqual(waiting.key, PaneKey(machine: "local", pane: 7))
        XCTAssertEqual(waiting.tab, 107)
        XCTAssertTrue(waiting.canResolve)
        XCTAssertTrue(waiting.canMute)
        let working = card(entry(8, .running, attention: nil, canMute: false))
        XCTAssertFalse(working.canResolve, "nothing to resolve while it works")
        XCTAssertFalse(working.canMute)
        XCTAssertEqual(card(entry(9, .waiting, workspace: nil, tab: nil)).place, "zsh", "outside any tab: the pane's title")
    }

    func testGitAndPeekFollowTheMachinesFeatures() {
        let changes = PaneGit.Changes(uncommitted: .init(files: 6, added: 128, removed: 32))
        let git = PaneGit(repo: "clotho", branch: "mac/overview", changes: changes)
        let full = card(entry(1, .waiting), source(git: [1: git]))
        XCTAssertEqual(full.branch, "mac/overview")
        XCTAssertEqual(full.branchText, "mac/overview")
        XCTAssertEqual(full.changes, changes)
        XCTAssertTrue(full.hasPeek)

        let noCounts = card(entry(1, .waiting), source([.git], git: [1: git]))
        XCTAssertEqual(noCounts.branch, "mac/overview")
        XCTAssertNil(noCounts.changes, "only with git.changes")
        XCTAssertFalse(noCounts.hasPeek)

        let noGit = card(entry(1, .waiting), source([.gitChanges, .peek], git: [1: git]))
        XCTAssertNil(noGit.branch, "nothing of git without the feature")
        XCTAssertNil(noGit.changes)
        XCTAssertEqual(noGit.branchText, "no repo")

        XCTAssertEqual(card(entry(2, .waiting), source(git: [1: git])).branchText, "no repo", "a pane outside a repo")
        let detached = PaneGit(repo: "clotho", branch: nil, head: "da86700")
        XCTAssertEqual(card(entry(1, .waiting), source(git: [1: detached])).branchText, "@da86700")
        XCTAssertFalse(card(entry(1, .waiting)).hasPeek, "a machine the source doesn't know")
    }

    // MARK: Spoken

    func testSpokenLabelSaysTheWholeCard() {
        let git = PaneGit(repo: "clotho", branch: "main", changes: .init(uncommitted: .init(files: 6, added: 128, removed: 32)))
        let ask = card(entry(1, .waiting, ago: 150, requests: [PermissionRequest(id: "r", tool: "Bash", summary: "cargo test")]),
                       source(git: [1: git]))
        XCTAssertEqual(ask.spoken, "Needs you: clotho › alerts. Allow Bash: cargo test. devbox, Claude. Waiting 2 min. Branch main. "
            + "128 lines added, 32 removed, in 6 files.")

        let done = card(entry(2, .done, needsUser: false, message: "All tests pass.", ago: 23 * 60, took: 8 * 60), source())
        XCTAssertEqual(done.spoken, "Done: clotho › alerts. All tests pass. devbox, Claude. Finished 23 min ago, took 8 min. No repo.")

        let failed = card(entry(3, .error, message: "API error", ago: 30))
        XCTAssertEqual(failed.spoken, "Error: clotho › alerts. API error. devbox, Claude. Waiting <1 min. No repo.")

        let working = card(entry(4, .running, muted: true, ago: nil, kind: "codex"))
        XCTAssertEqual(working.spoken, "Working: clotho › alerts. devbox, Codex, muted. No repo.")
    }

    // MARK: Filter

    private func mixed() -> [OverviewCard] {
        let git: [PaneID: PaneGit] = [1: PaneGit(repo: "clotho", branch: "fix/Relay-retry"), 3: PaneGit(repo: "site", branch: "main")]
        let local = cards([
            entry(1, .waiting, workspace: "Platform", tab: "cargo test"),
            entry(2, .error, ago: 300, workspace: "Platform", tab: "deploy"),
            entry(3, .running, attention: nil, kind: "codex", workspace: "Website", tab: "landing"),
        ], source(git: git))
        let remote = cards([
            entry(4, .done, needsUser: false, machine: "m2", machineName: "MacBook", workspace: "Docs", tab: "protocol"),
        ])
        return local + remote
    }

    func testFilterMatchesEveryField() {
        let all = mixed()
        func panes(_ query: String) -> [PaneID] { OverviewModel.filter(all, query: query).map(\.key.pane) }
        XCTAssertEqual(panes(""), [2, 1, 3, 4])
        XCTAssertEqual(panes("   "), [2, 1, 3, 4])
        XCTAssertEqual(panes("macbook"), [4], "the machine")
        XCTAssertEqual(panes("PLAT"), [2, 1], "the workspace, in any case")
        XCTAssertEqual(panes("landing"), [3], "the tab")
        XCTAssertEqual(panes("relay"), [1], "the branch")
        XCTAssertEqual(panes("codex"), [3], "the agent")
        XCTAssertEqual(panes("claude code"), [2, 1, 4], "the agent's full name")
        XCTAssertEqual(panes("devbox plat test"), [1], "every word, each in any field")
        XCTAssertEqual(panes("devbox docs"), [])
        XCTAssertEqual(panes("repo"), [], "\"no repo\" isn't a branch")
    }

    func testFilterByStateWords() {
        let all = mixed()
        func panes(_ query: String) -> [PaneID] { OverviewModel.filter(all, query: query).map(\.key.pane) }
        XCTAssertEqual(panes("needs"), [2, 1], "the failed one too")
        XCTAssertEqual(panes("needs you"), [2, 1])
        XCTAssertEqual(panes("Needs You deploy"), [2])
        XCTAssertEqual(panes("working"), [3])
        XCTAssertEqual(panes("done"), [4])
        XCTAssertEqual(panes("done working"), [3, 4])
        XCTAssertEqual(panes("done devbox"), [])
        XCTAssertEqual(panes("you"), [], "\"you\" alone is a word like any other")
    }

    func testFilteringLanesDropsTheEmptiedOnes() {
        let lanes = OverviewModel.lanes([
            entry(1, .waiting, workspace: "Platform"), entry(2, .running, attention: nil, workspace: "Website"),
            entry(3, .done, needsUser: false, workspace: "Platform"),
        ], now: now)
        let left = OverviewModel.filter(lanes, query: "platform")
        XCTAssertEqual(left.map(\.lane), [.needsYou, .done])
        XCTAssertEqual(left.map { $0.cards.map(\.key.pane) }, [[1], [3]])
        XCTAssertEqual(OverviewModel.filter(lanes, query: "").map(\.lane), [.needsYou, .working, .done])
    }

    // MARK: Layout

    func testColumnsForAWidth() {
        let layout = OverviewLayout()
        XCTAssertEqual(layout.columns(width: 1140), 4)
        XCTAssertEqual(layout.columns(width: 760), 2)
        XCTAssertEqual(layout.columns(width: 300), 1)
        XCTAssertEqual(layout.columns(width: 100), 1)
        XCTAssertEqual(layout.columns(width: 0), 1)
        XCTAssertEqual(layout.columns(width: -50), 1)
        XCTAssertEqual(layout.columns(width: .nan), 1)
        XCTAssertEqual(layout.columns(width: 36 + 250 * 2 + 10), 2, "exactly two cards and a gap")
        XCTAssertEqual(layout.columns(width: 36 + 250 * 2 + 9), 1)
    }

    func testFramesForLanes() {
        let layout = OverviewLayout()
        let frames = layout.frames(lanes: [5, 2], width: 1140)
        XCTAssertEqual(layout.cardWidth(width: 1140), 268)
        XCTAssertEqual(frames.headers, [CGRect(x: 18, y: 0, width: 1104, height: 28), CGRect(x: 18, y: 316, width: 1104, height: 28)])
        XCTAssertEqual(frames.cards.map(\.count), [5, 2])
        XCTAssertEqual(frames.cards[0][0], CGRect(x: 18, y: 28, width: 268, height: 132))
        XCTAssertEqual(frames.cards[0][3], CGRect(x: 18 + 3 * 278, y: 28, width: 268, height: 132))
        XCTAssertEqual(frames.cards[0][4], CGRect(x: 18, y: 170, width: 268, height: 132), "the second row")
        XCTAssertEqual(frames.cards[1][1], CGRect(x: 296, y: 344, width: 268, height: 132))
        XCTAssertEqual(frames.height, 476)
        XCTAssertLessThanOrEqual(frames.cards[0][3].maxX, 1140 - 18)

        let narrow = layout.frames(lanes: [2], width: 300)
        XCTAssertEqual(narrow.cards[0].map(\.minY), [28, 170], "one column")
        XCTAssertEqual(narrow.cards[0][0].width, 264)
        XCTAssertEqual(layout.frames(lanes: [], width: 1140), OverviewLayout.Frames(headers: [], cards: [], height: 0))
    }

    func testArrowMoves() {
        // Four columns; rows: [0 1 2 3] [4] | [5 6] | [7 8 9].
        let lanes = [5, 2, 3]
        func move(_ index: Int, _ direction: OverviewLayout.Direction) -> Int {
            OverviewLayout.move(from: index, direction: direction, in: lanes, columns: 4)
        }
        XCTAssertEqual(OverviewLayout.rows(lanes: lanes, columns: 4), [0..<4, 4..<5, 5..<7, 7..<10])
        XCTAssertEqual(move(1, .right), 2)
        XCTAssertEqual(move(3, .right), 4, "on to the next row")
        XCTAssertEqual(move(4, .right), 5, "on to the next lane")
        XCTAssertEqual(move(5, .left), 4)
        XCTAssertEqual(move(0, .left), 0)
        XCTAssertEqual(move(9, .right), 9)
        XCTAssertEqual(move(0, .down), 4)
        XCTAssertEqual(move(2, .down), 4, "a short row: its last card")
        XCTAssertEqual(move(4, .down), 5, "into the next lane")
        XCTAssertEqual(move(6, .down), 8, "the same column across lanes")
        XCTAssertEqual(move(8, .down), 8, "the last row")
        XCTAssertEqual(move(9, .up), 6, "clamped to the row above")
        XCTAssertEqual(move(6, .up), 4)
        XCTAssertEqual(move(4, .up), 0)
        XCTAssertEqual(move(3, .up), 3, "the first row")
        XCTAssertEqual(move(42, .left), 8, "an index past the end counts as the last")
        XCTAssertEqual(OverviewLayout.move(from: 0, direction: .down, in: [], columns: 4), 0)
        XCTAssertEqual(OverviewLayout.move(from: 0, direction: .down, in: [0, 2], columns: 0), 1, "never fewer than one column")
        XCTAssertEqual(OverviewLayout.move(from: 1, direction: .up, in: [3], columns: 1), 0)
    }

    func testSelectionStaysOnItsPaneAcrossAReSort() {
        func key(_ pane: PaneID, _ machine: MachineKey = "local") -> PaneKey { PaneKey(machine: machine, pane: pane) }
        let before = cards([entry(1, .waiting, ago: 300), entry(2, .waiting, ago: 200), entry(3, .running, attention: nil)]).map(\.key)
        XCTAssertEqual(before, [key(1), key(2), key(3)])
        // Pane 1 goes back to work: it moves from the head of Needs you into Working.
        let after = cards([entry(1, .running, attention: nil, ago: 1), entry(2, .waiting, ago: 200), entry(3, .running, attention: nil)]).map(\.key)
        XCTAssertEqual(after, [key(2), key(1), key(3)])
        XCTAssertEqual(OverviewLayout.selectionAfter(change: after, selected: key(1), at: 0), 1, "the same pane")
        XCTAssertEqual(OverviewLayout.selectionAfter(change: after, selected: key(1, "m2"), at: 0), 0, "the same id on another machine is another pane")
        // The selected card left: the one now nearest its place.
        XCTAssertEqual(OverviewLayout.selectionAfter(change: [key(2), key(3)], selected: key(1), at: 0), 0)
        XCTAssertEqual(OverviewLayout.selectionAfter(change: [key(1), key(2)], selected: key(3), at: 2), 1)
        XCTAssertEqual(OverviewLayout.selectionAfter(change: [key(1), key(2)], selected: nil, at: nil), 0, "nothing selected yet: the first")
        XCTAssertNil(OverviewLayout.selectionAfter(change: [], selected: key(1), at: 0))
    }

    // MARK: Peek

    func testPeekWantedSkipsMachinesWithoutPeek() {
        var source = OverviewSource()
        source.features = ["local": [.peek, .git], "old": [.git], "m2": [.peek]]
        let all = cards([
            entry(9, .waiting), entry(3, .running, attention: nil), entry(5, .done, needsUser: false),
            entry(4, .waiting, machine: "old", machineName: "old box"),
            entry(2, .waiting, machine: "m2", machineName: "macbook"),
            entry(7, .waiting, attention: false, machine: "m2", machineName: "macbook"),
        ], source)
        XCTAssertEqual(OverviewModel.peekWanted(cards: all), ["local": [3, 5, 9], "m2": [2]])
        XCTAssertEqual(OverviewModel.peekWanted(cards: []), [:])
    }
}
