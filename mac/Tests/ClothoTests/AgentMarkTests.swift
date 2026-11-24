import AppKit
import ClothoKit
import XCTest
@testable import Clotho

/// The state every surface draws an agent from: its mark, the inbox's sections, and the texts beside it.
@MainActor
final class AgentMarkTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func agent(_ state: AgentInfo.State, attention: Bool? = true, needsUser: Bool? = nil, settling: Bool? = nil,
                       muted: Bool? = nil, message: String? = nil, since: Double? = 100,
                       requests: [PermissionRequest]? = nil, summary: String? = nil) -> AgentInfo {
        AgentInfo(kind: "claude", state: state, source: "hook", message: message, since: since, attention: attention,
                  muted: muted, requests: requests, summary: summary, needsUser: needsUser, settling: settling)
    }

    private func entry(_ pane: PaneID, _ info: AgentInfo) -> AgentEntry {
        AgentEntry(machine: "local", machineName: "Mac", pane: pane, workspace: nil, tab: nil, paneTitle: nil, tabTitle: nil,
                   info: info, canReply: false)
    }

    // MARK: The mark

    func testTheMarkForEveryState() {
        XCTAssertEqual(agent(.waiting, needsUser: true).mark, .needsYou)
        XCTAssertEqual(agent(.error, needsUser: true).mark, .error)
        XCTAssertEqual(agent(.done, needsUser: true).mark, .needsYou, "a finished turn that asks something")
        XCTAssertEqual(agent(.done, needsUser: false).mark, .done)
        XCTAssertEqual(agent(.done).mark, .done, "an older daemon's done")
        XCTAssertEqual(agent(.running, attention: nil).mark, .working)
        XCTAssertEqual(agent(.starting, attention: nil).mark, .working)
        XCTAssertNil(agent(.waiting, attention: false).mark, "a quiet wait is idle")
        XCTAssertNil(agent(.done, attention: false, needsUser: true).mark, "resolved")
        XCTAssertNil(agent(.error, attention: false).mark, "resolved")
        XCTAssertNil(agent(.done, attention: false, settling: true).mark, "settling")
        XCTAssertNil(agent(.done, attention: true, needsUser: true, settling: true).mark, "settling, whatever attention says")
        XCTAssertNil(agent(.unknown, attention: nil).mark)
    }

    func testMutedAgentsOnlyShowWhileTheyWork() {
        XCTAssertNil(agent(.waiting, muted: true).mark)
        XCTAssertNil(agent(.done, needsUser: true, muted: true).mark)
        XCTAssertNil(agent(.error, muted: true).mark)
        XCTAssertEqual(agent(.running, attention: nil, muted: true).mark, .working)
    }

    /// Nothing with attention disappears: a bell while it runs (or in a state this app doesn't know).
    func testAttentionOutsideAFinishedTurnNeedsYou() {
        XCTAssertEqual(agent(.running).mark, .needsYou)
        XCTAssertEqual(agent(.starting).mark, .needsYou)
        XCTAssertEqual(agent(.unknown).mark, .needsYou)
    }

    func testLabels() {
        XCTAssertEqual(AgentMark.allCases.map(\.label), ["Needs you", "Error", "Done", "Working"])
    }

    // MARK: A place's mark

    func testAPlaceShowsItsMostUrgentMarkAndHowManyCarryIt() {
        XCTAssertNil(AgentMark.summary(of: []))
        XCTAssertNil(AgentMark.summary(of: [agent(.done, attention: false), agent(.waiting, attention: false)]))
        XCTAssertEqual(AgentMark.summary(of: [agent(.running, attention: nil), agent(.starting, attention: nil), agent(.done, attention: false)]),
                       AgentMarkCount(mark: .working, count: 2))
        XCTAssertEqual(AgentMark.summary(of: [agent(.running, attention: nil), agent(.done, needsUser: false)]),
                       AgentMarkCount(mark: .done, count: 1), "a finished turn before a running one")
        XCTAssertEqual(AgentMark.summary(of: [agent(.done, needsUser: false), agent(.error), agent(.done, needsUser: true)]),
                       AgentMarkCount(mark: .error, count: 1), "a failure before a finished turn that asks")
        // Waiting first; the finished turn that asks carries the same mark, the failure doesn't.
        XCTAssertEqual(AgentMark.summary(of: [agent(.error), agent(.done, needsUser: true), agent(.waiting), agent(.done, needsUser: false)]),
                       AgentMarkCount(mark: .needsYou, count: 2))
        XCTAssertEqual(AgentMark.summary(of: [agent(.done, needsUser: false), agent(.running)]),
                       AgentMarkCount(mark: .needsYou, count: 1), "a bell before a plain done")
    }

    // MARK: The inbox

    func testInboxSectionsAndOrder() {
        let entries = [
            entry(1, agent(.waiting, since: 300)),
            entry(2, agent(.error, since: 100)),
            entry(3, agent(.done, needsUser: true, since: 200)),
            entry(4, agent(.waiting, since: nil)),
            entry(5, agent(.done, needsUser: false, since: 50)),
            entry(6, agent(.done, since: 400)),
            entry(7, agent(.running, attention: nil, since: 10)),
            entry(8, agent(.starting, attention: nil, since: 500)),
            entry(9, agent(.done, attention: false, settling: true, since: 600)),
            entry(10, agent(.waiting, muted: true, since: 1)),
            entry(11, agent(.done, attention: false, since: 700)),
            entry(12, agent(.waiting, attention: false, since: 800)),
        ]
        let sections = AgentInbox.sections(entries)
        XCTAssertEqual(sections.needsYou.map(\.pane), [2, 3, 1, 4], "the longest wait first, the failure among them, no time last")
        XCTAssertEqual(sections.done.map(\.pane), [6, 5], "most recent first")
        XCTAssertEqual(sections.working.map(\.pane), [8, 7], "most recent first")
        let listed = Set((sections.needsYou + sections.done + sections.working).map(\.pane))
        XCTAssertTrue(listed.isDisjoint(with: [9, 10, 11, 12]), "settling, muted, resolved and idle agents are in no section")
    }

    func testEmptyInbox() {
        let sections = AgentInbox.sections([])
        XCTAssertTrue(sections.needsYou.isEmpty && sections.done.isEmpty && sections.working.isEmpty)
    }

    // MARK: Texts

    func testAskText() {
        XCTAssertEqual(PermissionRequest(id: "r1", tool: "Bash", summary: "npm test").askText, "Allow Bash: npm test")
        XCTAssertEqual(PermissionRequest(id: "r2", tool: "Edit").askText, "Allow Edit")
        XCTAssertEqual(PermissionRequest(id: "r3", tool: "Bash", summary: "ls  -la\n| wc").askText, "Allow Bash: ls -la | wc")
        XCTAssertEqual(PermissionRequest(id: "r4", tool: "Bash", summary: "test -f a?").askText, "Allow Bash: test -f a?", "only the question's own mark goes")
    }

    func testInboxText() {
        let requests = [PermissionRequest(id: "r1", tool: "Bash", summary: "npm test"), PermissionRequest(id: "r2", tool: "Edit", summary: "a.swift")]
        XCTAssertEqual(agent(.waiting, message: "Claude needs your permission to use Bash", requests: requests, summary: "Running the tests").inboxText,
                       "Allow Bash: npm test", "the oldest pending request")
        XCTAssertEqual(agent(.done, needsUser: true, message: "All set.\n\nWhich **database** should I use?", summary: "Which database?").inboxText,
                       "Which database?", "the daemon's summary of what it asks")
        let said = agent(.done, needsUser: false, message: "Fixed the build.\nTests pass.").inboxText
        XCTAssertEqual(said?.contains("\n"), false, "one line")
        XCTAssertEqual(said?.hasPrefix("Fixed the build."), true, "what it last said")
        XCTAssertNil(agent(.running, attention: nil).inboxText)
    }

    func testElapsedText() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(AgentMark.needsYou.elapsedText(since: 10_000 - 125, now: now), "waiting 2 min")
        XCTAssertEqual(AgentMark.working.elapsedText(since: 10_000 - 6 * 60, now: now), "6 min")
        XCTAssertEqual(AgentMark.needsYou.elapsedText(since: 10_000 - 20, now: now), "waiting <1 min")
        XCTAssertEqual(AgentMark.working.elapsedText(since: 10_000 + 30, now: now), "<1 min", "a clock ahead of ours")
        XCTAssertEqual(AgentMark.working.elapsedText(since: 10_000 - 2 * 3600 - 60, now: now), "2 h")
        XCTAssertEqual(AgentMark.needsYou.elapsedText(since: 10_000 - 3 * 86400, now: now), "waiting 3 d")
        XCTAssertEqual(AgentMark.done.elapsedText(since: 10_000 - 125, now: now), "")
        XCTAssertEqual(AgentMark.error.elapsedText(since: 10_000 - 125, now: now), "")
        XCTAssertEqual(AgentMark.needsYou.elapsedText(since: nil, now: now), "")
    }

    // MARK: Colours

    private func hex(_ color: NSColor, _ appearance: ClothoPalette.Appearance) -> UInt32 {
        var value: UInt32 = 0
        NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            value = UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8
                | UInt32((c.blueComponent * 255).rounded())
        }
        return value
    }

    func testStateColoursAreThePalettes() {
        for appearance in ClothoPalette.Appearance.allCases {
            let palette = ClothoPalette.for(appearance)
            XCTAssertEqual(hex(Theme.danger, appearance), palette.ansi[1], "\(appearance)")
            XCTAssertEqual(hex(Theme.success, appearance), palette.ansi[2], "\(appearance)")
            XCTAssertEqual(hex(Theme.caution, appearance), palette.ansi[3], "\(appearance)")
            XCTAssertEqual(hex(AgentMark.needsYou.color, appearance), palette.ansi[3])
            XCTAssertEqual(hex(AgentMark.error.color, appearance), palette.ansi[1])
            XCTAssertEqual(hex(AgentMark.done.color, appearance), palette.ansi[2])
            XCTAssertEqual(hex(AgentMark.working.color, appearance), palette.accent)
            for mark in AgentMark.allCases {
                XCTAssertEqual(hex(mark.color, appearance), mark.hex(for: appearance))
            }
        }
        XCTAssertEqual(AgentInfo.State.waiting.color, Theme.caution)
    }

    /// `tint` laid over `under`, as the screen shows it.
    private func blend(_ tint: UInt32, alpha: Double, over under: UInt32) -> UInt32 {
        [UInt32(16), 8, 0].reduce(UInt32(0)) { result, shift in
            let mixed = Double((tint >> shift) & 0xff) * alpha + Double((under >> shift) & 0xff) * (1 - alpha)
            return result | UInt32(mixed.rounded()) << shift
        }
    }

    func testChipTextReadsOnItsTint() {
        for appearance in ClothoPalette.Appearance.allCases {
            let palette = ClothoPalette.for(appearance)
            XCTAssertEqual(hex(Theme.foreground, appearance), palette.foreground, "the chip's text colour")
            let alpha = Double(AgentMark.tintAlpha(for: appearance))
            for mark in AgentMark.allCases {
                XCTAssertEqual(mark.tint(for: appearance).alphaComponent, CGFloat(alpha), accuracy: 0.001)
                for (name, under) in [("chrome", palette.chrome), ("background", palette.background)] {
                    let chip = blend(mark.hex(for: appearance), alpha: alpha, over: under)
                    XCTAssertGreaterThanOrEqual(ClothoPalette.contrast(palette.foreground, chip), 4.5, "\(mark) over \(name), \(appearance)")
                    XCTAssertGreaterThan(ClothoPalette.contrast(chip, under), 1.1, "\(mark)'s tint shows on \(name), \(appearance)")
                }
            }
        }
    }

    // MARK: Views

    func testChipContent() {
        XCTAssertEqual(AgentChip.content(AgentMarkCount(mark: .needsYou, count: 3)), .count(3))
        XCTAssertEqual(AgentChip.content(AgentMarkCount(mark: .error, count: 1)), .count(1))
        XCTAssertEqual(AgentChip.content(AgentMarkCount(mark: .working, count: 2)), .count(2))
        XCTAssertEqual(AgentChip.content(AgentMarkCount(mark: .done, count: 2)), .check)
        let chip = AgentChip(AgentMarkCount(mark: .needsYou, count: 3))
        XCTAssertEqual(chip.label.stringValue, "3")
        XCTAssertFalse(chip.label.isHidden)
        XCTAssertTrue(chip.check.isHidden)
        XCTAssertEqual(chip.accessibilityLabel(), "Needs you: 3 agents")
        XCTAssertEqual(chip.intrinsicContentSize.height, AgentChip.height)
        let one = chip.intrinsicContentSize.width
        chip.value = AgentMarkCount(mark: .needsYou, count: 128)
        XCTAssertGreaterThan(chip.intrinsicContentSize.width, one, "a pill for more digits")
        chip.value = AgentMarkCount(mark: .done, count: 1)
        XCTAssertTrue(chip.label.isHidden)
        XCTAssertFalse(chip.check.isHidden)
        XCTAssertEqual(chip.accessibilityLabel(), "Done")
        XCTAssertEqual(chip.intrinsicContentSize.width, AgentChip.height, "a circle")
    }

    func testMarkViewSpinsOnlyWhileWorkingInAWindow() {
        let reduces = AgentMarkView.reducesMotion
        defer { AgentMarkView.reducesMotion = reduces }
        AgentMarkView.reducesMotion = { false }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let view = AgentMarkView(.working)
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: AgentMarkView.side, height: AgentMarkView.side))
        XCTAssertEqual(view.accessibilityLabel(), "Working")
        XCTAssertFalse(view.isSpinning, "still outside a window")
        window.contentView!.addSubview(view)
        XCTAssertTrue(view.isSpinning)
        view.mark = .needsYou
        XCTAssertFalse(view.isSpinning, "a dot")
        XCTAssertEqual(view.accessibilityLabel(), "Needs you")
        view.mark = .working
        XCTAssertTrue(view.isSpinning)
        view.removeFromSuperview()
        XCTAssertFalse(view.isSpinning)

        AgentMarkView.reducesMotion = { true }
        window.contentView!.addSubview(view)
        XCTAssertFalse(view.isSpinning, "Reduce Motion: a still ring")
        for mark in [AgentMark.needsYou, .error, .done] {
            let dot = AgentMarkView(mark)
            window.contentView!.addSubview(dot)
            XCTAssertFalse(dot.isSpinning)
            XCTAssertEqual(dot.accessibilityLabel(), mark.label)
        }
    }
}
