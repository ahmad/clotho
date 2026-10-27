import SwiftUI
import UIKit

@main
struct ClothoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var machines = MachineList()
    @StateObject private var connections = Connections()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The caret blinks with a repeating animation, so XCUITest would never see the app idle.
        if ProcessInfo.processInfo.arguments.contains("-UITesting") { UIView.setAnimationsEnabled(false) }
        AgentNotifier.shared.setUp()
    }

    var body: some Scene {
        WindowGroup {
            MachineListView()
                .environmentObject(machines)
                .environmentObject(connections)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends a backgrounded app, so close connections deliberately and resume them on return:
            // each pane resubscribes with the seq it reached and picks up in live or replay mode.
            switch phase {
            case .background: connections.suspendAll()
            case .active: connections.resumeAll()
            default: break
            }
        }
    }
}
