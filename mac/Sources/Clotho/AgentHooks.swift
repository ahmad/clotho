import AppKit
import ClothoKit

// "Agent Status…": clothod's hooks for the coding agents on a machine (Claude Code, Codex, Gemini CLI,
// GitHub Copilot CLI, and whatever a later clothod lists in `hooks status`), so they report exactly when
// they're waiting, done or failing instead of being detected from the terminal. Each agent has its own
// Install, Update and Remove (AgentHooksList.swift). Nothing is installed, updated or removed until the
// user has seen what it does (`clothod hooks print <agent>`) and confirmed, one agent at a time.

/// One line of `clothod hooks status`: an agent and whether its hooks are there.
struct HookLine: Equatable {
    enum State: Equatable { case installed, outdated, notInstalled }
    /// The agent's name as clothod printed it. Always a valid kind name (`AgentKind.isValidName`), so it
    /// can be handed back to `clothod hooks print|install|uninstall` as one word.
    var agent: String
    var state: State
    /// clothod's hook is called by another program's (Codex's `notify` chained by Computer Use): it runs.
    var chained = false

    /// "Installed", "Installed (chained)", "Update available", "Not installed".
    var caption: String {
        switch state {
        case .installed: return chained ? "Installed (chained)" : "Installed"
        case .outdated: return "Update available"
        case .notInstalled: return "Not installed"
        }
    }
}

/// What the app knows of the machines' agent hooks.
@MainActor
final class AgentHooksState {
    /// `hooks status` per machine, in clothod's order. No entry: not asked yet, or it couldn't say.
    var lines: [MachineKey: [HookLine]] = [:]
    /// The agents a command is running for, as "machine/agent": their buttons are off meanwhile.
    var busy: Set<String> = []
    /// Tests put their own clothod here: every `clothod` command of the app goes through it instead.
    var runner: ((MachineKey, [String]) async throws -> RemoteCommandResult)?

    /// Posted (object: the machine's key) when a machine's lines or busy agents change.
    static let changed = Notification.Name("ClothoAgentHooksChanged")
    func announce(_ key: MachineKey) { NotificationCenter.default.post(name: Self.changed, object: key) }
}

extension AppDelegate {
    /// `hooks status` per machine: agent → installed (an outdated one isn't).
    var hookStatus: [MachineKey: [String: Bool]] {
        agentHooks.lines.mapValues { lines in
            Dictionary(lines.map { ($0.agent, $0.state == .installed) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Runs `clothod <arguments>` on a machine, off the main thread.
    func runClothod(on key: MachineKey, _ arguments: [String]) async throws -> RemoteCommandResult {
        if let runner = agentHooks.runner { return try await runner(key, arguments) }
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

    /// The hooks (or notify command) already there for one agent that aren't Clotho's, which installing
    /// keeps. Read-only. Claude Code's and Gemini CLI's settings have the same shape; Copilot's file is
    /// Clotho's own, and for any other agent nothing is known.
    func existingAgentHooks(_ agent: String, on key: MachineKey) async -> [String] {
        // A test's clothod: the user's own files are none of its business.
        guard agentHooks.runner == nil else { return [] }
        var kept: [String] = []
        let name = AgentKind.of(agent).name
        switch agent {
        case "claude", "gemini":
            let file = agent == "claude" ? "~/.claude/settings.json" : "~/.gemini/settings.json"
            if let result = try? await runShell(on: key, "cat \(file) 2>/dev/null"),
               let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
               let hooks = json["hooks"] as? [String: Any] {
                for (event, groups) in hooks.sorted(by: { $0.key < $1.key }) {
                    for group in groups as? [[String: Any]] ?? [] {
                        for hook in group["hooks"] as? [[String: Any]] ?? [] {
                            guard let command = hook["command"] as? String, !command.contains("clotho-agent-status") else { continue }
                            kept.append("\(name) \(event): \(command.count > 90 ? command.prefix(90) + "…" : command)")
                        }
                    }
                }
            }
        case "codex":
            if let result = try? await runShell(on: key, "grep -E '^[[:space:]]*notify[[:space:]]*=' ~/.codex/config.toml 2>/dev/null"),
               let line = result.stdout.split(separator: "\n").first.map(String.init), !line.contains("clotho-notify") {
                kept.append("Codex notify: \(line.trimmingCharacters(in: .whitespaces)) (still runs, after Clotho's)")
            }
        default:
            break
        }
        return kept
    }

    /// Whether agent status is set up on the machine: at least one agent's hooks are installed there, or a
    /// coding agent there has already reported through its hooks (a script's `clothod report` doesn't count).
    func hasHookSourcedAgents(_ key: MachineKey) -> Bool {
        if agentHooks.lines[key]?.contains(where: { $0.state != .notInstalled }) == true { return true }
        return hookSourcedMachines.contains(key)
            || connections[key]?.store.state.panes.contains { $0.agent.map(Self.showsHooksAreSetUp) == true } == true
    }

    /// Asks the machine's clothod which agents have hooks (`hooks status`: "claude: installed" lines).
    /// Read-only.
    func refreshHookStatus(_ key: MachineKey) {
        Task { @MainActor in
            guard let result = try? await runClothod(on: key, ["hooks", "status"]), result.status == 0 else { return }
            let lines = Self.parseHookLines(result.stdout)
            guard agentHooks.lines[key] != lines else { return }
            agentHooks.lines[key] = lines
            agentHooks.announce(key)
            onboarding?.refreshHooks()
        }
    }

    /// `hooks status` output, in its order: one line per agent, "<name>: installed", "outdated" or "not
    /// installed", with an optional qualifier after ("installed (chained)", clothod 0.1.17+: clotho's
    /// Codex hook called by another `notify` program, and it still runs). "outdated" (0.1.11+) is an older
    /// clothod's hooks, which `hooks install` replaces in place. Any agent a clothod names is kept (0.1.33
    /// has four; a later one may have more). A line that isn't `<valid name>: <status>` is dropped: the
    /// name later goes to a command line.
    nonisolated static func parseHookLines(_ output: String) -> [HookLine] {
        var lines: [HookLine] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, AgentKind.isValidName(parts[0]), !lines.contains(where: { $0.agent == parts[0] }) else { continue }
            let words = parts[1].split(separator: " ", maxSplits: 1).map(String.init)
            let state: HookLine.State
            switch words.first {
            case "installed": state = .installed
            case "outdated": state = .outdated
            case "not" where words.count == 2 && words[1].hasPrefix("installed"): state = .notInstalled
            default: continue
            }
            lines.append(HookLine(agent: parts[0], state: state, chained: words.count == 2 && words[1].contains("(chained)")))
        }
        return lines
    }

    /// The same as two lookups: whether each agent's hooks are installed, and which are outdated.
    nonisolated static func parseHookStatus(_ output: String) -> (installed: [String: Bool], outdated: Set<String>) {
        let lines = parseHookLines(output)
        return (Dictionary(lines.map { ($0.agent, $0.state == .installed) }, uniquingKeysWith: { first, _ in first }),
                Set(lines.filter { $0.state == .outdated }.map(\.agent)))
    }

    /// Whether an agent's hooks on the machine came from an older clothod, to update.
    func hooksNeedUpdate(_ key: MachineKey) -> Bool {
        agentHooks.lines[key]?.contains { $0.state == .outdated } == true
    }

    /// The machine menu's item, always there for a machine that can be asked: "Update Agent Status…" when
    /// any hook is outdated, "Set Up Agent Status…" while nothing is installed and no coding agent has
    /// reported through hooks, else "Agent Status…".
    nonisolated static func hooksMenuTitle(lines: [HookLine]?, seenHookAgent: Bool) -> String {
        if lines?.contains(where: { $0.state == .outdated }) == true { return "Update Agent Status…" }
        if lines?.contains(where: { $0.state == .installed }) == true || seenHookAgent { return "Agent Status…" }
        return "Set Up Agent Status…"
    }

    func hooksMenuTitle(_ key: MachineKey) -> String {
        Self.hooksMenuTitle(lines: agentHooks.lines[key], seenHookAgent: hasHookSourcedAgents(key))
    }

    /// The rows a machine's list shows: clothod's lines, or before it answered the agents every clothod
    /// since 0.1.33 knows (nil states: not known yet).
    func hookRows(_ key: MachineKey) -> [(agent: String, line: HookLine?)] {
        if let lines = agentHooks.lines[key], !lines.isEmpty { return lines.map { ($0.agent, $0) } }
        return AgentKind.hookable.map { ($0, nil) }
    }

    /// Opens the machine's agent status sheet: every agent with its own Install, Update and Remove.
    func setUpAgentHooks(on key: MachineKey, in parent: NSWindow? = nil) {
        let window: NSWindow = parent ?? self.window
        guard let session = connections[key], window.attachedSheet == nil else { return }
        refreshHookStatus(key)
        let sheet = AgentHooksSheet(app: self, key: key, machineName: session.title)
        log("hooks: agent status sheet for \(session.title)")
        window.beginSheet(sheet) { _ in }
    }

    /// What `clothod hooks install <agent>` is about to do, in words, above its own preview.
    nonisolated static func hooksPreviewLead(_ agent: String) -> String {
        switch agent {
        case "claude": return "Claude Code: adds these hooks to ~/.claude/settings.json:"
        case "codex": return "Codex: sets `notify` in ~/.codex/config.toml:"
        case "gemini": return "Gemini CLI: adds these hooks to ~/.gemini/settings.json:"
        case "copilot": return "GitHub Copilot CLI: writes ~/.copilot/hooks/clotho.json, a file of Clotho\u{2019}s own:"
        default: return "`clothod hooks install \(agent)` makes these changes:"
        }
    }

    /// Install (or Update, for outdated hooks) for one agent: asks clothod what would change, shows it,
    /// and runs `hooks install <agent>` only on the confirming click.
    func installHooks(agent: String, on key: MachineKey, in window: NSWindow) {
        guard AgentKind.isValidName(agent), let session = connections[key], window.attachedSheet == nil,
              !agentHooks.busy.contains("\(key)/\(agent)") else { return }
        let machine = session.title
        let name = AgentKind.of(agent).name
        let updating = agentHooks.lines[key]?.first { $0.agent == agent }?.state == .outdated
        setHooksBusy(agent, on: key, true)
        Task { @MainActor [self] in
            let preview: String
            do {
                let result = try await runClothod(on: key, ["hooks", "print", agent])
                guard result.status == 0 else {
                    setHooksBusy(agent, on: key, false)
                    return showHooksFailure(machine, "clothod on \(machine) can't set up \(name) yet.", detail: result.stderr, in: window)
                }
                preview = result.stdout
            } catch {
                setHooksBusy(agent, on: key, false)
                return showHooksFailure(machine, "Couldn't ask clothod on \(machine) what would change.", detail: error.localizedDescription, in: window)
            }
            let kept = await existingAgentHooks(agent, on: key)
            setHooksBusy(agent, on: key, false)
            guard window.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.messageText = updating ? "Update the status hooks for \(name) on \(machine)?" : "Install status hooks for \(name) on \(machine)?"
            alert.informativeText = "\(name) will report when it starts, waits for you, finishes or fails, instead of Clotho guessing "
                + "from the terminal. Clotho runs `clothod hooks install \(agent)` on \(machine), which makes the changes below and keeps "
                + "a backup of any file it edits. Remove undoes it."
                + (agent == "copilot" ? "\n\n" + AgentHookRow.copilotNote : "")
            alert.addButton(withTitle: updating ? "Update" : "Install")
            alert.addButton(withTitle: "Cancel")
            let keptText = kept.isEmpty ? "" : "Already set up on \(machine), and kept as they are:\n" + kept.map { "  • " + $0 }.joined(separator: "\n") + "\n\n"
            alert.accessoryView = Self.preview(keptText + Self.hooksPreviewLead(agent) + "\n\n" + preview)
            log("hooks: asking to \(updating ? "update" : "install") \(agent) on \(machine)")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return log("hooks: install of \(agent) cancelled on \(machine)") }
                self.runHooks("install", agent: agent, on: key, machine: machine, failure: "Installing the status hooks for \(name) on \(machine) didn't finish.", in: window)
            }
        }
    }

    /// Remove for one agent: asks, and runs `hooks uninstall <agent>` only on the confirming click.
    func removeHooks(agent: String, on key: MachineKey, in window: NSWindow) {
        guard AgentKind.isValidName(agent), let session = connections[key], window.attachedSheet == nil,
              !agentHooks.busy.contains("\(key)/\(agent)") else { return }
        let machine = session.title
        let name = AgentKind.of(agent).name
        let alert = NSAlert()
        alert.messageText = "Remove Clotho\u{2019}s status hooks for \(name) on \(machine)?"
        alert.informativeText = "Clotho runs `clothod hooks uninstall \(agent)` on \(machine). \(name) is then detected from the terminal again, "
            + "which is less exact. Anything else in its settings stays."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        log("hooks: asking to remove \(agent) on \(machine)")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return log("hooks: removal of \(agent) cancelled on \(machine)") }
            self.runHooks("uninstall", agent: agent, on: key, machine: machine, failure: "Removing the status hooks for \(name) on \(machine) didn't finish.", in: window)
        }
    }

    /// The confirmed command, for one agent; then the status again, and clothod's words if it failed.
    private func runHooks(_ verb: String, agent: String, on key: MachineKey, machine: String, failure: String, in window: NSWindow) {
        guard AgentKind.isValidName(agent) else { return }
        setHooksBusy(agent, on: key, true)
        Task { @MainActor in
            var report = ""
            var failed = false
            do {
                let result = try await runClothod(on: key, ["hooks", verb, agent])
                failed = result.status != 0
                report = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            } catch {
                failed = true
                report = error.localizedDescription
            }
            log("hooks \(verb) \(agent) on \(machine): \(report)")
            setHooksBusy(agent, on: key, false)
            refreshHookStatus(key)
            if failed {
                showHooksFailure(machine, failure, detail: report, in: window, changedNothing: false)
            } else {
                if verb == "install" { hookSourcedMachines.insert(key) }
                sync()
            }
        }
    }

    private func setHooksBusy(_ agent: String, on key: MachineKey, _ busy: Bool) {
        if busy { agentHooks.busy.insert("\(key)/\(agent)") } else { agentHooks.busy.remove("\(key)/\(agent)") }
        agentHooks.announce(key)
    }

    private func showHooksFailure(_ name: String, _ message: String, detail: String, in window: NSWindow, changedNothing: Bool = true) {
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = changedNothing ? "Nothing was changed on \(name)." : "This is what clothod on \(name) said."
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
