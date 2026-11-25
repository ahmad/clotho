import ClothoKit
@testable import Clotho
import SwiftUI
import XCTest

/// The progress strip (`ProgressStrip`): what it draws for a pane's progress, what VoiceOver says, and which
/// progress a Tab shows, and when none is drawn at all.
final class ProgressStripTests: XCTestCase {
    func testFillFraction() throws {
        for (percent, fraction) in [(0, 0.0), (40, 0.4), (100, 1.0)] {
            let progress = PaneProgress(state: .running, percent: percent)
            XCTAssertEqual(try XCTUnwrap(ProgressStrip.fillFraction(progress)), fraction, accuracy: 0.0001, "\(percent)")
            XCTAssertFalse(ProgressStrip.isIndeterminate(progress), "\(percent)")
        }
        // A percent out of range is brought in, never drawn past the track.
        XCTAssertEqual(ProgressStrip.fillFraction(PaneProgress(state: .running, percent: 140)), 1)
        XCTAssertEqual(ProgressStrip.fillFraction(PaneProgress(state: .running, percent: -5)), 0)
    }

    func testIndeterminateHasNoFill() {
        XCTAssertNil(ProgressStrip.fillFraction(PaneProgress(state: .indeterminate)))
        XCTAssertTrue(ProgressStrip.isIndeterminate(PaneProgress(state: .indeterminate)))
        // The daemon's percent is dropped for indeterminate.
        XCTAssertTrue(ProgressStrip.isIndeterminate(PaneProgress(state: .indeterminate, percent: 30)))
        // A state that gave no percent slides too.
        for state in [PaneProgress.State.running, .error, .paused] {
            XCTAssertTrue(ProgressStrip.isIndeterminate(PaneProgress(state: state)), "\(state)")
        }
    }

    func testTints() {
        XCTAssertEqual(ProgressStrip.tint(for: .running), .accentColor)
        XCTAssertEqual(ProgressStrip.tint(for: .indeterminate), .accentColor)
        XCTAssertEqual(ProgressStrip.tint(for: .error), .red)
        XCTAssertEqual(ProgressStrip.tint(for: .paused), .orange)
    }

    func testSpokenValue() {
        XCTAssertEqual(ProgressStrip.spokenValue(PaneProgress(state: .running, percent: 40)), "40 percent")
        XCTAssertEqual(ProgressStrip.spokenValue(PaneProgress(state: .error, percent: 55)), "55 percent, error")
        XCTAssertEqual(ProgressStrip.spokenValue(PaneProgress(state: .paused, percent: 70)), "70 percent, paused")
        XCTAssertEqual(ProgressStrip.spokenValue(PaneProgress(state: .indeterminate)), "in progress")
        XCTAssertEqual(ProgressStrip.spokenValue(PaneProgress(state: .error)), "error")
        XCTAssertEqual(ProgressStrip.spokenValue(PaneProgress(state: .paused)), "paused")
    }

    /// The segment starts fully off the leading edge and ends fully off the trailing one, once a period.
    func testSegmentSlidesAcrossOncePerPeriod() {
        let width: CGFloat = 200, segment = width * ProgressStrip.segmentShare
        XCTAssertEqual(ProgressStrip.segmentOffset(at: 0, width: width), -segment, accuracy: 0.001)
        XCTAssertEqual(ProgressStrip.segmentOffset(at: ProgressStrip.period / 2, width: width), -segment + (width + segment) / 2, accuracy: 0.001)
        // A later pass is like the first (a quarter into the fourth).
        XCTAssertEqual(ProgressStrip.segmentOffset(at: ProgressStrip.period * 3.25, width: width), -segment + (width + segment) / 4, accuracy: 0.001)
        XCTAssertLessThan(ProgressStrip.segmentOffset(at: ProgressStrip.period * 0.999, width: width), width)
    }

    // MARK: The Tab's progress

    private let tab = ClothoKit.Tab(id: 10, activePane: 100,
                          layout: .split(id: 1, axis: .horizontal, ratio: 0.5, a: .pane(100),
                                         b: .split(id: 2, axis: .vertical, ratio: 0.5, a: .pane(101), b: .pane(102))))

    private func state(_ progress: [PaneID: PaneProgress], exited: Set<PaneID> = []) -> ModelState {
        var state = ModelState()
        state.workspaces = [Workspace(id: 1, name: "api", tabs: [tab])]
        state.panes = [100, 101, 102].map {
            Pane(id: $0, cols: 80, rows: 24, exited: exited.contains($0) ? PaneExit(code: 0) : nil, progress: progress[$0])
        }
        return state
    }

    func testTabShowsTheFirstErrorElseTheFirst() {
        let running = PaneProgress(state: .running, percent: 20), paused = PaneProgress(state: .paused, percent: 60)
        let failed = PaneProgress(state: .error, percent: 55), failedLater = PaneProgress(state: .error, percent: 90)
        XCTAssertEqual(ModelStore.tabProgress(tab, in: state([101: paused, 102: running]), shows: true), paused, "the first in layout order")
        XCTAssertEqual(ModelStore.tabProgress(tab, in: state([100: running, 101: failed, 102: failedLater]), shows: true), failed, "the first error")
        XCTAssertNil(ModelStore.tabProgress(tab, in: state([:]), shows: true))
        // An exited pane's last progress isn't drawn.
        XCTAssertEqual(ModelStore.tabProgress(tab, in: state([100: failed, 102: running], exited: [100]), shows: true), running)
        XCTAssertNil(ModelStore.paneProgress(100, in: state([100: failed], exited: [100]), shows: true))
        XCTAssertEqual(ModelStore.paneProgress(101, in: state([101: paused]), shows: true), paused)
    }

    func testNoProgressWithoutTheFeatureConnectionOrLiveModel() {
        let features: Set<Hello.Feature> = [.paneProgress, .agents]
        XCTAssertTrue(ModelStore.showsProgress(features: features, connected: true, saved: false))
        XCTAssertFalse(ModelStore.showsProgress(features: [.agents], connected: true, saved: false), "no pane.progress feature")
        XCTAssertFalse(ModelStore.showsProgress(features: features, connected: false, saved: false), "not connected")
        XCTAssertFalse(ModelStore.showsProgress(features: features, connected: true, saved: true), "a saved model")
        XCTAssertFalse(ModelStore.showsProgress(features: features, connected: false, saved: true))

        let model = state([100: PaneProgress(state: .running, percent: 40)])
        XCTAssertNotNil(ModelStore.tabProgress(tab, in: model, shows: true))
        XCTAssertNil(ModelStore.tabProgress(tab, in: model, shows: false))
        XCTAssertNil(ModelStore.paneProgress(100, in: model, shows: false))
    }
}

/// The key bar's keys for VoiceOver and tests (`KeyBar`): words, never an SF Symbol's name.
@MainActor
final class KeyBarLabelTests: XCTestCase {
    func testEveryKeyHasARealLabelAndAnIdentifier() throws {
        let buttons = KeyBar(frame: CGRect(x: 0, y: 0, width: 320, height: KeyBar.height)).keyButtons
        XCTAssertEqual(buttons.count, 14)
        var labels: [String: String] = [:]
        for button in buttons {
            let label = try XCTUnwrap(button.accessibilityLabel), identifier = try XCTUnwrap(button.accessibilityIdentifier)
            XCTAssertFalse(label.isEmpty)
            XCTAssertFalse(label.contains("."), "\(identifier) reads its symbol's name: \(label)")
            XCTAssertTrue(identifier.hasPrefix("key."), identifier)
            XCTAssertNil(labels[identifier], "two keys are \(identifier)")
            labels[identifier] = label
        }
        XCTAssertEqual(labels["key.hideKeyboard"], "Hide Keyboard")
        XCTAssertEqual(labels["key.left"], "Left Arrow")
        XCTAssertEqual(labels["key.down"], "Down Arrow")
        XCTAssertEqual(labels["key.up"], "Up Arrow")
        XCTAssertEqual(labels["key.right"], "Right Arrow")
        XCTAssertEqual(labels["key.newline"], "Newline")
        XCTAssertEqual(labels["key.paste"], "Paste")
        XCTAssertEqual(labels["key.esc"], "esc")
    }
}
