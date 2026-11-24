import AppKit

/// Whether opening a file in its default app would run it. "Open in Editor" is for reading and editing a
/// file an agent may have just written: one that would run is shown in Finder instead.
enum OpenSafety {
    /// Kinds that are programs, or that make another app run or install something when opened: apps and
    /// bundles the system loads, Terminal's scripts and settings (a .terminal file carries a command),
    /// Automator's, installers, Java archives, and the shortcut files that open whatever they point at.
    static let runExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "workflow", "action", "pkg", "mpkg", "jar", "shortcut",
        "inetloc", "fileloc", "webloc", "url", "prefpane", "saver", "qlgenerator", "mobileconfig",
    ]

    /// Default apps that run what they're given: the terminals, and the launchers and installers.
    static let runnerApps: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.warp-stable", "net.kovidgoyal.kitty",
        "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby",
        "org.python.pythonlauncher", "com.apple.jarlauncher", "com.apple.installer", "com.apple.automatorinstaller",
        "com.apple.automator.runner",
    ]

    /// - name: the file's name or path.
    /// - isExecutable: a regular file with the exec bit.
    /// - defaultApp: the bundle id of the app that opens it, nil when there is none (or it isn't known).
    static func runsWhenOpened(name: String, isExecutable: Bool, defaultApp: String?) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if runExtensions.contains(ext) { return true }
        if let defaultApp { return runnerApps.contains(defaultApp.lowercased()) }
        // An executable nothing claims to edit.
        return isExecutable
    }

    /// The same, for a file on this Mac.
    static func runsWhenOpened(_ url: URL) -> Bool {
        let file = url.resolvingSymlinksInPath()
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
        let executable = values?.isRegularFile == true && values?.isExecutable == true
        let app = NSWorkspace.shared.urlForApplication(toOpen: file).flatMap { Bundle(url: $0)?.bundleIdentifier }
        return runsWhenOpened(name: url.lastPathComponent, isExecutable: executable, defaultApp: app)
            || runsWhenOpened(name: file.lastPathComponent, isExecutable: executable, defaultApp: app)
    }
}
