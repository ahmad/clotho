import AppKit
import ClothoKit

// When a newer clothod is installed but a machine's daemon still runs an older build, Clotho keeps using
// the running one and offers to switch. Switching restarts the daemon's logic process (the shells are
// kept), which the user sees, so it never happens without them asking.
extension AppDelegate {
    func offerDaemonUpdate(for key: MachineKey) {
        pendingDaemonUpdates.insert(key)
        showDaemonUpdateNotice()
    }

    // MARK: Legacy holders

    /// A holder too old to upgrade in place (hello's `holder_outdated`) only gets a new build when the
    /// machine's clothod restart, which ends its shells. Offered once per daemon instance; the user
    /// decides, and nothing restarts on its own.
    func offerHolderRestartIfNeeded(_ session: MachineConnection) {
        // The hello arrives through the event stream, just after start() returns.
        Task { @MainActor in
            for _ in 0..<20 where session.store.hello == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
            guard let hello = session.store.hello, hello.holderOutdated == true else { return }
            var shown = UserDefaults.standard.stringArray(forKey: "HolderRestartOffered") ?? []
            guard !shown.contains(hello.instance) else { return }
            shown.append(hello.instance)
            UserDefaults.standard.set(shown, forKey: "HolderRestartOffered")
            pendingHolderRestarts.insert(session.key)
            showHolderRestartNotice()
        }
    }

    private func showHolderRestartNotice() {
        let names = pendingHolderRestarts.compactMap { connections[$0]?.title }.sorted()
        guard !names.isEmpty else { return }
        let which = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        showNotice("\(which) \(names.count == 1 ? "runs" : "run") an older clothod that can't be updated in place. "
                   + "Restarting it finishes the update and ends every shell on \(which).", detail: nil, action: "Restart clothod…") { [weak self] in
            self?.confirmHolderRestarts()
        }
    }

    private func confirmHolderRestarts() {
        let keys = pendingHolderRestarts.filter { connections[$0] != nil }
        let names = keys.compactMap { connections[$0]?.title }.sorted()
        guard !names.isEmpty, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = names.count == 1 ? "Restart clothod on \(names[0])?" : "Restart clothod on \(names.count) machines?"
        alert.informativeText = "Every shell and program running in Clotho on \(names.joined(separator: ", ")) ends, "
            + "and its workspaces start again empty on the current clothod. Other machines aren't affected."
        alert.addButton(withTitle: "End all shells and restart")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            hideNotice()
            pendingHolderRestarts.subtract(keys)
            for key in keys {
                guard let session = connections[key] else { continue }
                if key == Self.localKey, let daemon = localDaemon {
                    Task.detached {
                        do { try daemon.restartClothod() } catch { log("clothod: restarting failed: \(error.localizedDescription)") }
                        await MainActor.run { session.store.backend.reconnectNow() }
                    }
                } else if let installer = remoteInstallers[key] {
                    // The bridge starts the machine's daemon again when Clotho reconnects.
                    Task.detached {
                        do { try installer.shutdownSessions() } catch { log("\(session.machine.label): restarting clothod failed: \(error.localizedDescription)") }
                        await MainActor.run { session.store.backend.reconnectNow() }
                    }
                }
            }
        }
    }

    /// Checks a remote machine after it connects.
    func checkRemoteDaemonUpdate(_ key: MachineKey) {
        guard let installer = remoteInstallers[key], installer.outdatedDaemonExe != nil else { return }
        offerDaemonUpdate(for: key)
    }

    private func showDaemonUpdateNotice() {
        let names = pendingDaemonUpdates.compactMap { connections[$0]?.title }.sorted()
        guard !names.isEmpty else { return }
        let which = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        showNotice("A clothod update is ready for \(which). Restart the daemon to use it; your shells keep running.",
                   detail: nil, action: names.count == 1 ? "Restart Daemon" : "Restart Daemons") { [weak self] in
            self?.applyDaemonUpdates()
        }
    }

    func applyDaemonUpdates() {
        hideNotice()
        let keys = pendingDaemonUpdates
        pendingDaemonUpdates.removeAll()
        for key in keys {
            guard let session = connections[key] else { continue }
            if key == Self.localKey {
                guard let daemon = localDaemon else { continue }
                Task { @MainActor in
                    do {
                        try await Task.detached { try daemon.upgrade() }.value
                        log("clothod: switched this Mac's daemon to the installed build")
                    } catch LocalDaemon.Failure.holderTooOld(let message) {
                        self.showNotice("This Mac runs an older clothod that can't be updated in place. Restarting it finishes the update and ends every shell on this Mac.",
                                        detail: message, action: "Restart clothod…") { [weak self] in self?.confirmRestartClothod() }
                    } catch {
                        log("clothod: switching builds failed: \(error.localizedDescription)")
                    }
                    // The backend reconnects by itself after the stop.
                }
            } else if let installer = remoteInstallers[key] {
                Task.detached {
                    let failure: String?
                    do {
                        try installer.switchToInstalledBuild()
                        failure = nil
                    } catch {
                        failure = error.localizedDescription
                        log("\(session.machine.label): switching builds failed: \(error.localizedDescription)")
                    }
                    await MainActor.run {
                        // An incompatible holder: the holder itself needs restarting, ending its shells, which the user decides.
                        if let failure, failure.contains("restart them") { self.offerRemoteRestart(key, message: failure) }
                        session.store.backend.reconnectNow()
                    }
                }
            }
        }
    }
}
