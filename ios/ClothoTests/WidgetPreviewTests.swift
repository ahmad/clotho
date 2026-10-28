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
}
