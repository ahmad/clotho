import AppKit
import ClothoKit

// "Set Up Agent Status…": installs clothod's hooks for Claude Code and Codex on a machine, so they report
// exactly when they're waiting, done or failing instead of being detected from the terminal. Nothing is
// installed until the user has seen what will change (`clothod hooks print`) and confirmed.
extension AppDelegate {
    nonisolated static let hookedAgents = ["claude", "codex"]

    /// Runs `clothod <arguments>` on a machine, off the main thread.
    func runClothod(on key: MachineKey, _ arguments: [String]) async throws -> RemoteCommandResult {
        if key == Self.localKey {
            guard let daemon = localDaemon else { throw RemoteInstaller.Failure(message: "This Mac's shells don't run on clothod.") }
            return try await Task.detached {
                let result = try daemon.runClothod(arguments)
                return RemoteCommandResult(status: result.status, stdout: result.stdout, stderr: result.stderr)
            }.value
        }
        guard let installer = remoteInstallers[key] else {
            throw RemoteInstaller.Failure(message: "Connect to the machine first.")
        }
        return try await Task.detached { try installer.runClothod(arguments) }.value
    }

    /// Runs a read-only shell command on a machine (here, or over ssh), for showing the user what's there.
    func runShell(on key: MachineKey, _ command: String) async throws -> RemoteCommandResult {
        if key == Self.localKey {
            return try await Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                try process.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return RemoteCommandResult(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self), stderr: "")
            }.value
        }
        guard let installer = remoteInstallers[key] else { throw RemoteInstaller.Failure(message: "Connect to the machine first.") }
        let runner = installer.runner
        return try await Task.detached { try runner.run(command, input: nil) }.value
    }

    /// The hooks and notify command already on the machine that aren't Clotho's, which installing keeps.
    func existingAgentHooks(on key: MachineKey) async -> [String] {
        var kept: [String] = []
        if let result = try? await runShell(on: key, "cat ~/.claude/settings.json 2>/dev/null"),
           let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
           let hooks = json["hooks"] as? [String: Any] {
            for (event, groups) in hooks.sorted(by: { $0.key < $1.key }) {
                for group in groups as? [[String: Any]] ?? [] {
                    for hook in group["hooks"] as? [[String: Any]] ?? [] {
                        guard let command = hook["command"] as? String, !command.contains("clotho-agent-status") else { continue }
                        kept.append("Claude Code \(event): \(command.count > 90 ? command.prefix(90) + "…" : command)")
                    }
                }
            }
        }
        if let result = try? await runShell(on: key, "grep -E '^[[:space:]]*notify[[:space:]]*=' ~/.codex/config.toml 2>/dev/null"),
           let line = result.stdout.split(separator: "\n").first.map(String.init), !line.contains("clotho-notify") {
            kept.append("Codex notify: \(line.trimmingCharacters(in: .whitespaces)) (still runs, after Clotho's)")
        }
        return kept
    }

    /// Whether agent status is set up on the machine: `hooks status` says so for every agent, or an agent
    /// there has already reported through hooks.
    func hasHookSourcedAgents(_ key: MachineKey) -> Bool {
        if let status = hookStatus[key], !status.isEmpty, status.values.allSatisfy({ $0 }) { return true }
        return hookSourcedMachines.contains(key)
            || connections[key]?.store.state.panes.contains { $0.agent?.isHookSourced == true } == true
    }

    /// Asks the machine's clothod which agents have hooks (`hooks status`: "claude: installed" lines).
    /// Read-only; it decides whether "Set Up Agent Status…" is offered.
    func refreshHookStatus(_ key: MachineKey) {
        Task { @MainActor in
            guard let result = try? await runClothod(on: key, ["hooks", "status"]), result.status == 0 else { return }
            let (status, outdated) = Self.parseHookStatus(result.stdout)
            hookStatus[key] = status
            if outdated.isEmpty { outdatedHooks.removeValue(forKey: key) } else { outdatedHooks[key] = outdated }
            onboarding?.refreshHooks()
        }
    }

    /// `hooks status` output: whether each agent's hooks are installed, and which are outdated.
    /// "outdated" (clothod 0.1.11+) is an older clothod's hooks, which `hooks install` replaces in place.
    /// A qualifier after the status counts as that status: "installed (chained)" (0.1.17+) is clotho's
    /// Codex hook called by another `notify` program (Codex Computer Use), and it still runs.
    nonisolated static func parseHookStatus(_ output: String) -> (installed: [String: Bool], outdated: Set<String>) {
        var status: [String: Bool] = [:]
        var outdated: Set<String> = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, hookedAgents.contains(parts[0]) else { continue }
            let value = parts[1].split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            // "not installed" reads as "not", so it's neither.
            status[parts[0]] = value == "installed"
            if value == "outdated" { outdated.insert(parts[0]) }
        }
        return (status, outdated)
    }

    /// Whether every agent needing hooks on the machine has older ones, to update rather than set up.
    func hooksNeedUpdate(_ key: MachineKey) -> Bool {
        let needed = agentsNeedingHooks(key)
        return !needed.isEmpty && needed.allSatisfy { outdatedHooks[key]?.contains($0) == true }
    }

    /// The agents that still need hooks on the machine (all of them if unknown).
    func agentsNeedingHooks(_ key: MachineKey) -> [String] {
        guard let status = hookStatus[key], !status.isEmpty else { return Self.hookedAgents }
        return Self.hookedAgents.filter { status[$0] != true }
    }

    /// Shows what installing the hooks changes on the machine, and installs them only if the user agrees.
    func setUpAgentHooks(on key: MachineKey, in parent: NSWindow? = nil) {
        let window: NSWindow = parent ?? self.window
        guard let session = connections[key], window.attachedSheet == nil else { return }
        let name = session.title
        guard !agentsNeedingHooks(key).isEmpty else {
            log("hooks: already set up on \(name)")
            return showNotice("Agent status is already set up on \(name).", detail: nil, action: nil, then: nil)
        }
        Task { @MainActor in
            var previews: [(agent: String, text: String)] = []
            for agent in agentsNeedingHooks(key) {
                do {
                    let result = try await runClothod(on: key, ["hooks", "print", agent])
                    guard result.status == 0 else {
                        return showHooksFailure(name, "clothod on \(name) can't set up agent status yet.", detail: result.stderr, in: window)
                    }
                    previews.append((agent, result.stdout))
                } catch {
                    return showHooksFailure(name, "Couldn't ask clothod on \(name) what would change.", detail: error.localizedDescription, in: window)
                }
            }
            let kept = await existingAgentHooks(on: key)
            confirmHooks(on: key, name: name, previews: previews, kept: kept, in: window)
        }
    }

    private func confirmHooks(on key: MachineKey, name: String, previews: [(agent: String, text: String)], kept: [String], in window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Set up agent status on \(name)?"
        alert.informativeText = "Claude Code and Codex will report when they start, wait for you, finish or fail, "
            + "instead of Clotho guessing from the terminal. Clotho runs `clothod hooks install` for each on \(name), "
            + "which makes the changes below and keeps a backup of each file it edits. "
            + "`clothod hooks uninstall` undoes it."
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Cancel")
        let keptText = kept.isEmpty
            ? "Nothing else is set up for these agents on \(name)."
            : "Already set up on \(name), and kept as they are:\n" + kept.map { "  • " + $0 }.joined(separator: "\n")
        alert.accessoryView = Self.preview(keptText + "\n\n" + previews.map { preview in
            let what = preview.agent == "claude"
                ? "Claude Code: adds these hooks to ~/.claude/settings.json:"
                : "Codex: sets `notify` in ~/.codex/config.toml:"
            return "\(what)\n\n\(preview.text)"
        }.joined(separator: "\n\n"))
        log("hooks: asking to set up \(previews.map(\.agent).joined(separator: ", ")) on \(name)")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return log("hooks: set up cancelled on \(name)") }
            Task { @MainActor in
                var report: [String] = []
                var failed = false
                for preview in previews {
                    do {
                        let result = try await self.runClothod(on: key, ["hooks", "install", preview.agent])
                        failed = failed || result.status != 0
                        report.append([result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n"))
                    } catch {
                        failed = true
                        report.append(error.localizedDescription)
                    }
                }
                log("hooks install on \(name): \(report.joined(separator: " | "))")
                self.refreshHookStatus(key)
                if failed {
                    self.showHooksFailure(name, "Setting up agent status on \(name) didn't finish.", detail: report.joined(separator: "\n\n"), in: window)
                } else {
                    self.hookSourcedMachines.insert(key)
                    self.showNotice("Agent status is set up on \(name). Agents started from now on report it.", detail: report.joined(separator: "\n"),
                                    action: nil, then: nil)
                    self.sync()
                }
            }
        }
    }

    private func showHooksFailure(_ name: String, _ message: String, detail: String, in window: NSWindow) {
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail.isEmpty ? "Nothing was changed on \(name)." : "Nothing was changed on \(name)."
        if !detail.isEmpty { alert.accessoryView = Self.preview(detail) }
        alert.beginSheetModal(for: window)
    }

    /// A scrolling, selectable monospaced text box for command output.
    static func preview(_ text: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 480, height: 220)
        scroll.borderType = .bezelBorder
        if let view = scroll.documentView as? NSTextView {
            view.string = text
            view.isEditable = false
            view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        return scroll
    }
}
