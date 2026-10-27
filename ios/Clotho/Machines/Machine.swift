import Foundation

/// A machine the app can connect to. Everything here is plain Codable data with a stable id and a
/// modification date, so the list can later sync through CloudKit (one record per machine, last writer
/// wins on `modifiedAt`). Private keys never sync: `keyID` names a Keychain key on this device, and a
/// machine synced from another device without that key asks for one.
struct Machine: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Remote: SSH to `host`, then `clothod bridge` over the exec channel.
        case ssh
        /// Simulator only: the Mac's own clothod over its Unix socket, for development before the bridge.
        case localSocket
    }

    var id: UUID
    var name: String
    var kind: Kind
    var host: String
    var port: Int
    var user: String
    /// The Keychain key used to log in (see `KeyStore`).
    var keyID: String?
    /// Install and run clothod in test directories on the machine, leaving the user's own daemon alone.
    var devDirs: Bool?
    /// The remote command that speaks the protocol on stdio. Nil uses the default bridge command.
    var remoteCommand: String?
    /// For `.localSocket`.
    var socketPath: String?
    /// Agent alerts from this machine while the app is closed (docs/push.md). Nil means on.
    var alerts: Bool?
    var modifiedAt: Date

    init(id: UUID = UUID(), name: String, kind: Kind = .ssh, host: String = "", port: Int = 22, user: String = "",
         keyID: String? = nil, devDirs: Bool? = nil, remoteCommand: String? = nil, socketPath: String? = nil,
         modifiedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.user = user
        self.keyID = keyID
        self.devDirs = devDirs
        self.remoteCommand = remoteCommand
        self.socketPath = socketPath
        self.modifiedAt = modifiedAt
    }

    static let defaultBridgeCommand = "clothod bridge"

    /// Why a host or user typed in can't be used, or nil. NIO SSH never hands them to a shell or an ssh
    /// command line, but a leading "-" (an option to ssh, e.g. -oProxyCommand=…), whitespace and control
    /// characters are never a real host or user, and refusing them keeps the machine usable from any SSH client.
    static func problem(host: String, user: String) -> String? {
        func bad(_ text: String) -> Bool {
            text.hasPrefix("-") || text.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
        }
        if bad(host) { return "A host can't start with \"-\" or contain spaces or control characters." }
        if bad(user) { return "A user name can't start with \"-\" or contain spaces or control characters." }
        if host.contains("@") { return "Put the user name in User, and only the host name in Host." }
        return nil
    }

    /// What a connection depends on. Accepting a host key or renaming doesn't change it.
    var endpoint: [String] {
        [kind.rawValue, host, String(port), user, keyID ?? "", remoteCommand ?? "", socketPath ?? "", String(devDirs ?? false)]
    }

    var displayName: String { name.isEmpty ? host : name }

    var subtitle: String {
        switch kind {
        case .ssh: return "\(user.isEmpty ? "" : user + "@")\(host)\(port == 22 ? "" : ":\(port)")"
        case .localSocket: return socketPath ?? ""
        }
    }

    #if targetEnvironment(simulator)
    /// The Mac's clothod, reachable because simulator apps share the host's filesystem. Start it with
    /// `clothod start --runtime-dir /tmp/cki-ios` (a short path, so the socket fits in sun_path).
    static let localDev = Machine(id: UUID(uuidString: "00000000-0000-0000-0000-00000000C10D")!, name: "Local Mac (dev)",
                                  kind: .localSocket, socketPath: "/tmp/cki-ios/clothod.sock",
                                  modifiedAt: .distantPast)
    #endif
}

/// The saved machine list, as JSON in Application Support. CloudKit sync will sit behind this type.
@MainActor
final class MachineList: ObservableObject {
    @Published private(set) var machines: [Machine] = []

    private let url: URL

    init(url: URL = MachineList.defaultURL) {
        self.url = url
        load()
    }

    nonisolated static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("machines.json")
    }

    /// Saved machines, plus the simulator's local dev machine.
    var all: [Machine] {
        #if targetEnvironment(simulator)
        return [Machine.localDev] + machines
        #else
        return machines
        #endif
    }

    func machine(_ id: UUID) -> Machine? { all.first { $0.id == id } }

    func save(_ machine: Machine) {
        var machine = machine
        machine.modifiedAt = Date()
        #if targetEnvironment(simulator)
        if machine.id == Machine.localDev.id { return }
        #endif
        if let index = machines.firstIndex(where: { $0.id == machine.id }) {
            machines[index] = machine
        } else {
            machines.append(machine)
        }
        persist()
    }

    func delete(_ id: UUID) {
        machines.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        machines = (try? JSONDecoder.iso.decode([Machine].self, from: data)) ?? []
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.iso.encode(machines).write(to: url, options: .atomic)
        } catch {
            log("saving machines failed: \(error)")
        }
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

func log(_ message: String) {
    NSLog("[Clotho] %@", message)
}
