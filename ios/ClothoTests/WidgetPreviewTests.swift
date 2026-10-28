import SwiftUI
import WidgetKit
import XCTest
@testable import Clotho

/// Renders the "Needs you" widget's sizes as images (attached to the test), for review: WidgetKit itself
/// can't be driven from XCUITest. Also checks each size renders at its usual point size.
@MainActor
final class WidgetPreviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_761_512_345)

    private var entry: NeedsYouEntry {
        let machine = UUID(uuidString: "00000000-0000-0000-0000-00000000C10D")!
        return NeedsYouEntry(date: now, summary: AgentsSummary(updated: now.timeIntervalSince1970, agents: [
            .init(machine: machine, machineName: "devbox", pane: 7, workspace: "Platform", kind: "claude", state: "waiting",
                  since: now.timeIntervalSince1970 - 120),
            .init(machine: machine, machineName: "devbox", pane: 9, workspace: "api-server", kind: "codex", state: "error",
                  since: now.timeIntervalSince1970 - 900),
            .init(machine: UUID(), machineName: "imac", pane: 3, workspace: "Notes", kind: "claude", state: "done",
                  since: now.timeIntervalSince1970 - 4000),
        ]))
    }

    func testRendersEverySize() throws {
        let sizes: [(WidgetFamily, CGSize, String)] = [
            (.systemSmall, CGSize(width: 170, height: 170), "small"),
            (.systemMedium, CGSize(width: 364, height: 170), "medium"),
            (.accessoryRectangular, CGSize(width: 172, height: 76), "lock screen rectangular"),
            (.accessoryCircular, CGSize(width: 76, height: 76), "lock screen circular"),
        ]
        for (family, size, name) in sizes {
            for scheme in [ColorScheme.light, .dark] {
                let view = NeedsYouView(entry: entry, family: family)
                    .padding(family == .systemSmall || family == .systemMedium ? 16 : 4)
                    .frame(width: size.width, height: size.height)
                    .background(family == .systemSmall || family == .systemMedium ? Color(.secondarySystemBackground) : Color.black.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: family == .accessoryCircular ? 38 : 20))
                    .environment(\.colorScheme, family == .accessoryRectangular || family == .accessoryCircular ? .dark : scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage, "\(name) didn't render")
                XCTAssertEqual(image.size, size, name)
                let shot = XCTAttachment(image: image)
                shot.name = "widget \(name) \(scheme == .light ? "light" : "dark")"
                shot.lifetime = .keepAlways
                add(shot)
            }
        }
    }

    func testEmptyWidgetSaysSo() throws {
        let empty = NeedsYouEntry(date: now, summary: .empty)
        XCTAssertNotNil(ImageRenderer(content: NeedsYouView(entry: empty, family: .systemSmall).frame(width: 170, height: 170)).uiImage)
    }

    #if LIVE_ACTIVITIES
    // The Live Activity's lock screen, with the detail (2026-10-28), for review.
    func testRendersTheLiveActivity() throws {
        let attributes = AgentActivityAttributes(machine: UUID(), pane: 7, machineName: "devbox", workspace: "Clotho",
                                                 tab: "orchestrator", prompt: "Make the Live Activity show what Claude is doing")
        let started = Int(Date().timeIntervalSince1970) - 754
        let states: [(String, AgentActivityAttributes.ContentState)] = [
            ("running", .init(state: "running", kind: "claude", since: started + 700, started: started, tool: "Bash",
                              detail: "cd ios && ./build.sh test -only-testing:ClothoTests/AgentActivityTests")),
            ("waiting", .init(state: "waiting", kind: "claude", since: started + 700, started: started, tool: "Bash",
                              detail: "rm -rf ios/build", msg: "Claude needs your permission to use Bash")),
            ("done", .init(state: "done", kind: "claude", since: started + 754, started: started,
                           msg: "The Live Activity now shows the tool, the command and the last message, and the timer sits on the right.")),
            ("old clothod", .init(state: "running", kind: "claude", since: started, started: started)),
        ]
        for (name, state) in states {
            for scheme in [ColorScheme.light, .dark] {
                let view = AgentActivityLockScreen(attributes: attributes, state: state)
                    .frame(width: 364)
                    .background(Color(.secondarySystemBackground))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage, "\(name) didn't render")
                XCTAssertEqual(image.size.width, 364, name)
                let shot = XCTAttachment(image: image)
                shot.name = "live activity \(name) \(scheme == .light ? "light" : "dark")"
                shot.lifetime = .keepAlways
                add(shot)
            }
        }
    }

    /// The user saw the timer centred: a timer Text fills the width it's given and centres in it. Rendered in
    /// the lock screen's 84 pt slot, its ink must end at the slot's right edge, running or finished.
    func testTimerHugsTheRightEdge() throws {
        let started = Int(Date().timeIntervalSince1970) - 75
        for state in [AgentActivityAttributes.ContentState(state: "running", kind: "claude", since: started, started: started),
                      .init(state: "done", kind: "claude", since: started + 75, started: started)] {
            let view = ActivityTimer(state: state).font(.title3.monospacedDigit()).foregroundStyle(.black)
                .frame(width: 84, height: 30, alignment: .trailing).background(.white)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let (left, right) = try XCTUnwrap(Self.inkColumns(image), state.state)
            XCTAssertGreaterThanOrEqual(right, 84 - 4, "\(state.state): the time ends at the right edge")
            XCTAssertGreaterThan(left, 20, "\(state.state): and doesn't start at the left (\(left)–\(right))")
        }
    }

    /// The first and last columns with any dark pixel.
    private static func inkColumns(_ image: CGImage) -> (Int, Int)? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let dark = (0..<width).filter { x in (0..<height).contains { y in pixels[(y * width + x) * 4] < 128 } }
        guard let first = dark.first, let last = dark.last else { return nil }
        return (first, last + 1)
    }
    #endif
}
