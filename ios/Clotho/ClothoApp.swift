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
        Onboarding.resetIfAsked()
        AgentNotifier.shared.setUp()
        TransferCenter.shared.removeOldDownloads()
        TransferCenter.shared.onDownloaded = { ShareSheet.present($0.localItems) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(machines)
                .environmentObject(connections)
                // Follows the system unless the user picked Light or Dark (the Machines toolbar).
                .onAppear { AppearanceChoice.applyToAllWindows() }
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends a backgrounded app, so close connections deliberately and resume them on return:
            // each pane resubscribes with the seq it reached and picks up in live or replay mode.
            switch phase {
            case .background: connections.suspendAll()
            case .active:
                connections.resumeAll()
                AgentNotifier.shared.refreshAuthorization()
            default: break
            }
        }
    }
}

/// The system share sheet (Save to Files, AirDrop, other apps) for downloaded files.
enum ShareSheet {
    @MainActor static func present(_ items: [URL]) {
        guard !items.isEmpty, var top = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 0, height: 0)
        top.present(sheet, animated: true)
    }
}
