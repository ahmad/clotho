import Foundation

public extension DaemonSettings.RewriteHealth {
    /// What to say under "Summarize agent messages" when the machine's rewrite isn't working: "Not
    /// working: <the daemon's reason, on one line>" (failing, shown in red), or that Claude Code is
    /// missing. Nil while there is nothing wrong to report (ok, off, unknown).
    var problemCaption: (text: String, failing: Bool)? {
        switch state {
        case .failing:
            // On one line, whatever the daemon sent.
            let reason = reason.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.flatMap { $0.isEmpty ? nil : $0 }
            return (reason.map { "Not working: \($0)" } ?? "Not working", true)
        case .unavailable:
            return ("Claude Code wasn't found on this machine", false)
        case .ok, .unknown, .off:
            return nil
        }
    }
}
