import ClothoKit
import SwiftUI

/// Answers a waiting agent without opening its pane: one tap for the usual choices of a permission prompt
/// (1, 2, 3 or Esc), or typed text followed by Enter.
struct QuickReplySheet: View {
    let row: AgentRow
    let connection: MachineConnection
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AgentRowView(row: row)
                }
                Section("Choose") {
                    HStack {
                        choice("1") { send(text: nil, keys: ["1"]) }
                        choice("2") { send(text: nil, keys: ["2"]) }
                        choice("3") { send(text: nil, keys: ["3"]) }
                        choice("Enter") { send(text: nil, keys: ["enter"]) }
                        choice("Esc") { send(text: nil, keys: ["escape"]) }
                    }
                    .buttonStyle(.bordered)
                }
                Section("Reply") {
                    TextField("Message", text: $text, axis: .vertical)
                        .focused($focused)
                        .lineLimit(1...6)
                    Button("Send") { send(text: text, keys: ["enter"]) }
                        .disabled(text.isEmpty)
                }
            }
            .navigationTitle("Reply to \(row.info.kind.capitalized)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func choice(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action).frame(maxWidth: .infinity)
    }

    private func send(text: String?, keys: [String]) {
        connection.reply(to: row.pane, text: text, keys: keys)
        dismiss()
    }
}
