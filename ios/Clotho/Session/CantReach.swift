import ClothoKit
import SwiftUI

/// A machine whose automatic retries gave up (`RetryPolicy.remote`): "Can't reach <name>", why, and a
/// quiet Reconnect. Nothing while it's connected or still trying.
struct CantReachRow: View {
    @ObservedObject var connection: MachineConnection
    @ObservedObject private var store: ModelStore

    init(connection: MachineConnection) {
        self.connection = connection
        store = connection.store
    }

    var body: some View {
        if connection.cantReach {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Can't reach \(connection.machine.displayName)").font(.callout)
                    Text(connection.cantReachReason)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .accessibilityIdentifier("cantReachReason")
                }
                Spacer(minLength: 8)
                ReconnectButton(connection: connection)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("cantReach")
        }
    }
}

/// Tries the machine again now, and starts its automatic retries again.
struct ReconnectButton: View {
    let connection: MachineConnection

    var body: some View {
        Button("Reconnect") { connection.reconnect() }
            .buttonStyle(.bordered).controlSize(.small)
            .accessibilityIdentifier("reconnect")
    }
}
