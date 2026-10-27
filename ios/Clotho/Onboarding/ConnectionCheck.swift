import Darwin
import Foundation
import NIOCore
import NIOPosix

/// The steps that set up a new machine, each one separately so a failure says which step went wrong:
/// reach the SSH server and read its host key, then (once the user trusted it) log in with the key.
enum ConnectionCheck {
    /// What the machine said about itself once logged in.
    struct Login: Equatable {
        var system: String
    }

    /// The host key the machine presents (OpenSSH form), without trusting it.
    static func hostKey(of machine: Machine) async throws -> String {
        try await background { try SSHSession.presentedHostKey(host: machine.host, port: machine.port) }
    }

    /// Logs in with the machine's key and runs `uname -sm`. The host key must already be trusted.
    static func logIn(_ machine: Machine) async throws -> Login {
        try await background {
            let session = try SSHSession.connect(machine: machine)
            defer { session.close() }
            let result = try session.run("uname -sm", input: nil)
            guard result.status == 0 else {
                throw CheckFailure("Logged in, but the machine couldn't run a command (exit \(result.status)). \(result.stderr)")
            }
            return Login(system: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    struct CheckFailure: Error, LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// A sentence a person can act on, for any error the check can hit.
    static func describe(_ error: Error, machine: Machine) -> String {
        let host = machine.host, port = machine.port
        if let failure = error as? CheckFailure { return failure.message }
        if let ssh = error as? SSHError {
            switch ssh {
            case .keyRejected:
                return "\(host) didn't accept the key. Add the public key to ~/.ssh/authorized_keys for \(machine.user) on \(host) (the command below does it), then try again."
            default:
                return ssh.localizedDescription
            }
        }
        if let connection = error as? NIOConnectionError {
            if connection.dnsAError != nil || connection.dnsAAAAError != nil || connection.connectionErrors.isEmpty {
                return "Couldn't find \(host). Check the name, or use its IP address. A Tailscale name needs the Tailscale app connected on this device."
            }
            if let first = connection.connectionErrors.first { return describe(first.error, machine: machine) }
        }
        if let channel = error as? ChannelError {
            switch channel {
            case .connectTimeout:
                return "\(host) didn't answer on port \(port). Check that it's on and reachable from this device (same network, or Tailscale connected), and that SSH is enabled there."
            case .ioOnClosedChannel, .alreadyClosed, .eof:
                return "\(host) closed the connection. Check that port \(port) is its SSH port and that SSH logins are allowed for \(machine.user)."
            default:
                break
            }
        }
        if let io = error as? IOError {
            switch io.errnoCode {
            case ECONNREFUSED:
                return "\(host) refused the connection on port \(port). SSH isn't running there, or it listens on another port. On a Mac, turn on System Settings › General › Sharing › Remote Login."
            case EHOSTUNREACH, ENETUNREACH:
                return "There's no route to \(host) from this device. Check the network, or connect Tailscale."
            case ETIMEDOUT:
                return "\(host) didn't answer on port \(port). Check that it's on and reachable from this device."
            default:
                break
            }
        }
        let text = String(describing: error)
        if text.contains("Local network") || text.contains("EPERM") {
            return "iOS blocked the connection. Allow Local Network for Clotho in Settings › Privacy & Security › Local Network."
        }
        return error.localizedDescription == text ? "Couldn't connect: \(text)" : error.localizedDescription
    }
}
