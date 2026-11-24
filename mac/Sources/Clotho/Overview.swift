import AppKit
import ClothoKit

// The Overview in the window (View ▸ Overview, ⇧⌘0, "> Show Overview"): every agent's card, over all of
// the window under the window buttons. The view is OverviewView.swift and its model OverviewModel.swift.
//
// It covers the sidebar, the tab bar, the panes and the inspector, and the rule for what is covered is the
// centre diff's, made general (ChangesDiffView.swift): nothing under it acts or takes the keyboard.
//
// Peeks: while it shows, each machine with `peek` (clothod 0.1.32) is asked for the last lines of the
// panes whose cards are on screen, and nothing is asked once it closes.

extension AppDelegate {
    var isOverviewShown: Bool { overview?.isHidden == false }

    /// Builds the Overview, hidden, in the window's content. The caller pins it and puts the window
    /// buttons back above it.
    func makeOverview() -> OverviewView {
        let view = OverviewView(frame: .zero)
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onClose = { [weak self] in self?.closeOverview() }
        view.onOpen = { [weak self] key in self?.overviewOpen(key) }
        view.onOpenBeside = { [weak self] key in self?.overviewOpenBeside(key) }
        view.onResolve = { [weak self] key in self?.resolveAgent(machine: key.machine, pane: key.pane) }
        view.onMute = { [weak self] key, muted in self?.muteAgent(machine: key.machine, pane: key.pane, muted: muted) }
        view.onFilterChange = { [weak self] in self?.syncOverviewPeeks() }
        view.onTick = { [weak self] in
            guard let self, isOverviewShown else { return }
            updateOverview(agents: agentEntries(monitoredOnly: false))
        }
        container.addSubview(view)
        overview = view
        return view
    }

    /// View ▸ Overview (⇧⌘0): shows it, or goes back.
    @objc func toggleOverview(_ sender: Any?) {
        log("overview: \(isOverviewShown ? "hide" : "show") (\(Self.describeTrigger(sender)))")
        if isOverviewShown { closeOverview() } else { showOverview() }
    }

    /// Shows the Overview over the window and gives it the keyboard. Nothing under it changes: the focus
    /// stays where it is, and the centre diff, if up, stays up underneath.
    func showOverview() {
        guard let overview else { return }
        if !isOverviewShown {
            overview.isHidden = false
            overview.didShow()
            updateCoveredAccessibility()
        }
        updateOverview(agents: agentEntries(monitoredOnly: false))
        window.contentView?.layoutSubtreeIfNeeded()
        // The command bar, the shortcuts card or the file browser, when one is up, is above it and keeps
        // the keyboard; it gives it to the Overview when it closes (`returnKeyboardToPanes`).
        if quickOpen == nil, shortcutsOverlay == nil, fileBrowser == nil { window.makeFirstResponder(overview) }
    }

    /// Back to the window (Back, Esc, ⇧⌘0, ⌘W, or a command for what it covers). The peeks end, what was
    /// covered is uncovered, and the keyboard goes back to where it came from: the centre diff if that is
    /// up, else the focused pane's terminal. `restoreKeyboard` false leaves the keyboard to the caller.
    func closeOverview(restoreKeyboard: Bool = true) {
        guard isOverviewShown else { return }
        // Something above it (the command bar, a sheet's field) may hold the keyboard: it keeps it.
        let hadKeyboard = overview.hasKeyboard || window.firstResponder == nil || window.firstResponder === window
        endOverviewPeeks()
        overview.isHidden = true
        overview.didHide()
        updateCoveredAccessibility()
        if restoreKeyboard, hadKeyboard { returnKeyboardToPanes() }
    }

    /// The cards, from every connected machine's agents (`agentEntries(monitoredOnly: false)`: the
    /// Overview is of every machine, whatever its "monitor agents" switch says). Every sync while it shows.
    func updateOverview(agents: [AgentEntry]) {
        guard isOverviewShown else { return }
        var source = OverviewSource()
        for (key, session) in connections {
            source.features[key] = session.store.features
            for pane in session.store.state.panes {
                if let git = pane.git { source.git[PaneKey(machine: key, pane: pane.id)] = git }
            }
        }
        overview.update(lanes: OverviewModel.lanes(agents, source: source))
        syncOverviewPeeks()
    }

    // MARK: Opening

    /// Return, a double-click, the menu's Open: the agent's pane, in view.
    func overviewOpen(_ key: PaneKey) {
        // Closed here, not by the focus moving: opening the pane that is already focused moves nothing.
        closeOverview(restoreKeyboard: false)
        openAgent(machine: key.machine, pane: key.pane)
        // Nothing moved (it was the focused pane), so no sync gave the keyboard to anything.
        let responder = window.firstResponder
        if responder == nil || responder === window || responder === overview || (responder as? NSView)?.isDescendant(of: overview) == true {
            returnKeyboardToPanes()
        }
    }

    static let besideOtherMachine = "Open Beside works within one machine"
    static let besideSameTab = "Already in this Tab"
    static let besideUnsupported = "Open Beside needs a newer clothod on this machine"

    /// ⌘↩: the agent's whole Tab moves beside the pane that is focused under the Overview, by the command
    /// bar's rule (`canOpenBeside`): the same machine, a daemon with `pane.move`, another Tab. Otherwise
    /// a beep and a line saying why, and the Overview stays.
    func overviewOpenBeside(_ key: PaneKey) {
        let origin = (machine: focusedMachine, pane: store.focusedPane?.id, tab: store.focusedTab?.id)
        let context = commandBarContext(.agent(machine: key.machine, pane: key.pane), origin: origin)
        guard context.canOpenBeside, let tab = context.tab, let pane = origin.pane, let store = connections[key.machine]?.store else {
            let why: String
            if key.machine != origin.machine {
                why = Self.besideOtherMachine
            } else if context.tab != nil, context.tab == origin.tab {
                why = Self.besideSameTab
            } else {
                why = Self.besideUnsupported
            }
            log("overview: no open beside for \(key.machine)/\(key.pane): \(why)")
            OverviewView.beep()
            overview.showNote(why)
            return
        }
        openBeside(tab: tab, beside: pane, in: store)
    }

    // MARK: Peeks

    /// Each machine's peek subscription follows the cards on screen: sent when the panes change (a new
    /// card, one gone, the filter) or the daemon is another instance (its old lines are dropped), and
    /// ended when no card of the machine is left or the machine is gone.
    func syncOverviewPeeks() {
        guard isOverviewShown else { return }
        let wanted = OverviewModel.peekWanted(cards: overview.shownCards)
        for (machine, panes) in wanted {
            guard let store = connections[machine]?.store else { continue }
            let instance = store.hello?.instance
            if let sent = overviewPeeks[machine] {
                guard sent.panes != panes || sent.instance != instance else { continue }
                // Another instance: what the old one sent is of other panes' screens.
                if sent.instance != instance { dropOverviewPeekLines(machine: machine, keeping: []) }
            }
            overviewPeeks[machine] = (panes, instance)
            dropOverviewPeekLines(machine: machine, keeping: Set(panes))
            let backend = store.backend
            sendOverviewPeek {
                // The lines come as `peek` events (`overviewPeek`), never from this reply.
                do { _ = try await backend.peekSubscribe(panes: panes, lines: PeekLines.requested) } catch {
                    log("overview: peek.subscribe on \(machine) failed: \(error.localizedDescription)")
                }
            }
        }
        for machine in Array(overviewPeeks.keys) where wanted[machine] == nil { endOverviewPeek(machine) }
    }

    /// Sends a peek request after the ones before it have been answered.
    private func sendOverviewPeek(_ request: @escaping @MainActor () async -> Void) {
        let before = overviewPeekRequests
        overviewPeekRequests = Task { @MainActor in
            await before?.value
            await request()
        }
    }

    /// Ends one machine's subscription and forgets its lines.
    private func endOverviewPeek(_ machine: MachineKey) {
        overviewPeeks[machine] = nil
        dropOverviewPeekLines(machine: machine, keeping: [])
        guard let backend = connections[machine]?.store.backend else { return }
        sendOverviewPeek {
            do { try await backend.peekUnsubscribe() } catch {
                log("overview: peek.unsubscribe on \(machine) failed: \(error.localizedDescription)")
            }
        }
    }

    /// The Overview closes: nothing is asked of any daemon for a view nobody sees.
    private func endOverviewPeeks() {
        for machine in Array(overviewPeeks.keys) { endOverviewPeek(machine) }
        overviewPeekLines.removeAll()
        overview.clearPeeks()
    }

    private func dropOverviewPeekLines(machine: MachineKey, keeping panes: Set<PaneID>) {
        for key in Array(overviewPeekLines.keys) where key.machine == machine && !panes.contains(key.pane) {
            overviewPeekLines[key] = nil
            overview.setPeek(key, lines: [])
        }
    }

    /// A `peek` event: the last lines of a pane's screen. Kept as sent; the card shows the two rows worth
    /// showing (`PeekLines.pick`: no input box, no empty prompt).
    func overviewPeek(machine: MachineKey, pane: PaneID, lines: [String]) {
        // One still on its way from a subscription since replaced.
        guard isOverviewShown, overviewPeeks[machine]?.panes.contains(pane) == true else { return }
        let key = PaneKey(machine: machine, pane: pane)
        guard overviewPeekLines[key] != lines else { return }
        overviewPeekLines[key] = lines
        overview.setPeek(key, lines: PeekLines.pick(lines))
    }
}
