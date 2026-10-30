import ClothoKit
import SwiftUI

/// A pane clothod brought back after a restart (`restored`, 0.1.21) shows a quiet note at the terminal's top
/// right, over it (taking no rows, so the shell's size never changes): "Restored after restart", plus
/// "· resumed Claude session" when it resumed one, or "Continued the latest conversation in this folder"
/// (0.1.25). × dismisses it on the machine, for every device; the machine also drops it on the first typing.
struct RestoredNote: View {
    let restore: PaneRestore
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.clockwise").font(.caption2.weight(.medium)).accessibilityHidden(true)
            Text(restore.note)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("restoredText")
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption2.weight(.semibold))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("dismissRestored")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 9)
        .frame(minHeight: 28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        // An edge, so it reads over a light pane too.
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .frame(maxWidth: 300, alignment: .trailing)
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("restoredNote")
    }

    #if DEBUG
    /// UI tests and screenshots (`-PreviewRestored resumed|continued|plain`): every pane shows that mark.
    static var preview: PaneRestore? {
        switch UserDefaults.standard.string(forKey: "PreviewRestored") {
        case "resumed": return PaneRestore(at: Date().timeIntervalSince1970, agent: "claude", session: "0d6f2c1e")
        case "continued": return PaneRestore(at: Date().timeIntervalSince1970, agent: "claude", continued: true)
        case "plain": return PaneRestore(at: Date().timeIntervalSince1970)
        default: return nil
        }
    }
    #endif
}
