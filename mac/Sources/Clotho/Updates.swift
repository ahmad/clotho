import AppKit
import Sparkle

// In-app updates with Sparkle 2: Clotho › Check for Updates…, and a daily automatic check. Updates come
// from the appcast at SUFeedURL (https://clotho.app/appcast.xml), and Sparkle installs one only if it's
// signed with the EdDSA key whose public half is SUPublicEDKey in Info.plist. The private key never
// leaves the release Mac's keychain (scripts/release.sh, README "Releases").
//
// The dev build has no feed and never updates; a build without SUPublicEDKey (the key isn't made yet)
// has updates turned off rather than accepting unsigned ones. Until the appcast is hosted, plain installs
// get no feed either (UPDATES_LIVE in build-app.sh), and Info.plist says so (ClothoUpdateFeedNotLive).

@MainActor
final class Updates: NSObject {
    private(set) var controller: SPUStandardUpdaterController?

    /// Why updates are off in this build, or nil when they're on.
    let unavailableReason: String?

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = info["SUFeedURL"] as? String ?? ""
        let key = info["SUPublicEDKey"] as? String ?? ""
        if isDevBuild {
            unavailableReason = "Clotho Dev doesn't update itself."
        } else if info["ClothoUpdateFeedNotLive"] as? Bool == true {
            unavailableReason = "Clotho's update feed isn't online yet, so this build doesn't check for updates."
        } else if feed.isEmpty || key.isEmpty {
            unavailableReason = "This build of Clotho was made without an update signing key, so it can't check for updates."
        } else {
            unavailableReason = nil
        }
        super.init()
        guard unavailableReason == nil else {
            log("updates: off (\(unavailableReason!))"
                + (info["ClothoUpdateFeedNotLive"] as? Bool == true ? " [UPDATES_LIVE is false in build-app.sh]" : ""))
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        log("updates: feed \(feed), automatic checks \(controller!.updater.automaticallyChecksForUpdates)")
    }

    var updater: SPUUpdater? { controller?.updater }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }
}

extension AppDelegate {
    @objc func checkForUpdates(_ sender: Any?) {
        if let controller = updates.controller {
            controller.checkForUpdates(sender)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Updates aren't available"
        alert.informativeText = updates.unavailableReason ?? ""
        alert.beginSheetModal(for: window)
    }
}
