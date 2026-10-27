import ClothoKit
import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

// SwiftNIO SSH for remote machines: one TCP connection per (re)connect, with an exec channel per remote
// step (probe, install, bridge), as docs/remote.md describes. Everything here blocks the calling thread,
// which is always a background one (ClothodTransport.open and RemoteCommandRunner.run).

enum SSHError: Error, LocalizedError {
    case noKey
    case keyMissing
    case keyRejected
    case hostKeyChanged(host: String, trusted: String, presented: String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .noKey: return "Choose a key for this machine first."
        case .keyMissing: return "This machine's key isn't on this device. Choose or generate another one."
        case .keyRejected: return "The server rejected the key. Add its public key to ~/.ssh/authorized_keys."
        case .hostKeyChanged(let host, let trusted, let presented):
            return "The host key for \(host) changed (was \(HostKeys.fingerprint(trusted) ?? "?"), now \(HostKeys.fingerprint(presented) ?? "?")). "
                + "Someone may be intercepting the connection. Not connecting."
        case .timedOut(let what): return "Timed out \(what)."
        }
    }
}

/// One authenticated SSH connection.
final class SSHSession: @unchecked Sendable {
    /// One event loop for all SSH traffic; channel handlers and glue all run on it.
    static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    let target: String
    private let channel: Channel
    private let errors: ErrorRecorder

    var isActive: Bool { channel.isActive }

    private init(target: String, channel: Channel, errors: ErrorRecorder) {
        self.target = target
        self.channel = channel
        self.errors = errors
    }

    /// Connects and authenticates (the handshake finishes when the first channel opens).
    static func connect(machine: Machine) throws -> SSHSession {
        guard let keyID = machine.keyID else { throw SSHError.noKey }
        guard let key = KeyStore.key(keyID) else { throw SSHError.keyMissing }
        let privateKey = try key.privateKey()
        let errors = ErrorRecorder()
        let userAuth = KeyAuthentication(user: machine.user, key: privateKey, errors: errors)
        let hostAuth = HostKeyValidator(machineID: machine.id, host: machine.host, errors: errors)
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: hostAuth)),
                                            allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandlers([ssh, ErrorHandler(errors: errors)])
                }
            }
        let channel = try bootstrap.connect(host: machine.host, port: machine.port).wait()
        return SSHSession(target: "\(machine.user)@\(machine.host)", channel: channel, errors: errors)
    }

    func close() {
        channel.close(promise: nil)
    }

    /// Opens a session channel and lets `configure` add its handlers.
    private func openChannel(_ configure: @escaping (Channel) throws -> Void) throws -> Channel {
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        // A connection that fails its handshake drops pending channels without failing them.
        channel.closeFuture.whenComplete { _ in promise.fail(ChannelError.ioOnClosedChannel) }
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            switch result {
            case .success(let handler):
                handler.createChannel(promise, channelType: .session) { child, type in
                    child.eventLoop.makeCompletedFuture {
                        guard type == .session else { throw ChannelError.badInterfaceAddressFamily }
                        try configure(child)
                    }
                }
            case .failure(let error):
                promise.fail(error)
            }
        }
        do {
            return try promise.futureResult.wait()
        } catch {
            // The connection's own failure (host key, auth) explains more than "channel closed".
            throw errors.first ?? error
        }
    }

    /// Runs `command` without a PTY, writes `input` to its stdin and closes it, and waits for it to end.
    func run(_ command: String, input: Data?) throws -> RemoteCommandResult {
        let done = channel.eventLoop.makePromise(of: RemoteCommandResult.self)
        do {
            _ = try openChannel { child in
                try child.pipeline.syncOperations.addHandler(ExecHandler(command: command, input: input, done: done))
            }
        } catch {
            done.fail(error)
            throw error
        }
        return try done.futureResult.wait()
    }

    /// Runs `command` without a PTY and returns its stdio as a ByteStream, through a socketpair: one end
    /// for ClothodBackend's reader and writer, the other glued to the channel on the event loop.
    func openStream(_ command: String) throws -> ByteStream {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw BackendError(code: "internal", message: "socketpair failed: \(String(cString: strerror(errno)))")
        }
        var on: Int32 = 1
        for fd in fds { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) }

        let (sshSide, pipeSide) = GlueHandler.matchedPair()
        let status = StreamStatus()
        let pipe: Channel
        do {
            // The pipe side is up first, so nothing the command prints is lost.
            pipe = try NIOPipeBootstrap(group: channel.eventLoop)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelInitializer { pipe in
                    pipe.eventLoop.makeCompletedFuture { try pipe.pipeline.syncOperations.addHandler(pipeSide) }
                }
                .takingOwnershipOfDescriptor(inputOutput: fds[1])
                .wait()
        } catch {
            Darwin.close(fds[0])
            Darwin.close(fds[1])
            throw error
        }
        let child: Channel
        do {
            child = try openChannel { child in
                try child.pipeline.syncOperations.addHandlers([BridgeHandler(command: command, status: status), sshSide])
            }
        } catch {
            pipe.close(promise: nil)
            Darwin.close(fds[0])
            throw error
        }
        let target = target, errors = errors
        return ByteStream(readFD: fds[0], writeFD: fds[0], onShutdown: {
            child.close(promise: nil)
            pipe.close(promise: nil)
        }, closeReason: {
            // The exit status arrives just before the channel closes; give it a moment.
            let deadline = Date().addingTimeInterval(1)
            while status.exit == nil, child.isActive, Date() < deadline { usleep(20_000) }
            let stderr = status.stderr
            if let error = errors.first { return error.localizedDescription }
            switch status.exit {
            case nil, 0?: return stderr.isEmpty ? nil : stderr
            case RemoteSetup.holderTooOldExit?:
                return "clothod on \(target) needs its sessions restarted to finish upgrading. \(stderr)"
            case let code?: return "clothod on \(target) exited with \(code)" + (stderr.isEmpty ? "" : ": \(stderr)")
            }
        })
    }
}

/// Runs remote setup steps over one SSH connection, which `reset` replaces before every connect.
final class NIOCommandRunner: RemoteCommandRunner, @unchecked Sendable {
    let machine: Machine
    private let lock = NSLock()
    private var current: SSHSession?

    init(machine: Machine) {
        self.machine = machine
    }

    var target: String { "\(machine.user)@\(machine.host)" }

    /// The connection, made if there isn't a live one.
    func session() throws -> SSHSession {
        lock.lock()
        defer { lock.unlock() }
        if let current, current.isActive { return current }
        let session = try SSHSession.connect(machine: machine)
        current = session
        return session
    }

    /// Drops the connection, so the next step makes a fresh one (after a disconnect or a heartbeat timeout).
    func reset() {
        lock.lock()
        let old = current
        current = nil
        lock.unlock()
        old?.close()
    }

    func run(_ command: String, input: Data?) throws -> RemoteCommandResult {
        do {
            return try session().run(command, input: input)
        } catch {
            // As with OpenSSH: 255 means ssh itself failed.
            reset()
            return RemoteCommandResult(status: 255, stdout: "", stderr: error.localizedDescription)
        }
    }
}

// MARK: - Authentication

/// Offers the machine's key once; a second request means the server rejected it.
private final class KeyAuthentication: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let user: String
    private let key: NIOSSHPrivateKey
    private let errors: ErrorRecorder
    private var offered = false

    init(user: String, key: NIOSSHPrivateKey, errors: ErrorRecorder) {
        self.user = user
        self.key = key
        self.errors = errors
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else {
            errors.record(SSHError.keyRejected)
            nextChallengePromise.fail(SSHError.keyRejected)
            return
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: user, serviceName: "",
                                                                  offer: .privateKey(.init(privateKey: key))))
    }
}

/// Trust on first use: the first key a machine presents is stored; a different one later is refused,
/// and the app is told so it can show the change and let the user decide.
private final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let machineID: UUID
    private let host: String
    private let errors: ErrorRecorder

    init(machineID: UUID, host: String, errors: ErrorRecorder) {
        self.machineID = machineID
        self.host = host
        self.errors = errors
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = HostKeys.openSSH(hostKey)
        guard let trusted = TrustedHostKeys.shared.key(for: machineID) else {
            log("trusting \(host)'s host key on first use: \(HostKeys.fingerprint(presented) ?? presented)")
            TrustedHostKeys.shared.set(presented, for: machineID)
            validationCompletePromise.succeed(())
            return
        }
        if trusted == presented {
            validationCompletePromise.succeed(())
            return
        }
        let error = SSHError.hostKeyChanged(host: host, trusted: trusted, presented: presented)
        errors.record(error)
        validationCompletePromise.fail(error)
        // Posted from the main queue, never from here: observers with `queue: .main` (every
        // MachineConnection) make `post` wait for the main thread, which would stall the one SSH event
        // loop every machine shares, and deadlock it outright while anything on main waits for SSH.
        let info: [String: Any] = ["machine": machineID, "trusted": trusted, "presented": presented]
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .hostKeyChanged, object: nil, userInfo: info)
        }
    }
}

extension Notification.Name {
    static let hostKeyChanged = Notification.Name("ClothoHostKeyChanged")
}

/// Accepted host keys by machine id, in OpenSSH form. Kept outside the machine record so a connection
/// can read and write it from any thread; it syncs alongside the machine list later.
final class TrustedHostKeys: @unchecked Sendable {
    static let shared = TrustedHostKeys()
    private let lock = NSLock()
    private let defaultsKey = "TrustedHostKeys"

    func key(for machine: UUID) -> String? {
        lock.withLock { (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String])?[machine.uuidString] }
    }

    func set(_ key: String?, for machine: UUID) {
        lock.withLock {
            var all = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
            all[machine.uuidString] = key
            UserDefaults.standard.set(all, forKey: defaultsKey)
        }
    }
}

// MARK: - Channel handlers

/// The first error a connection hit, which explains later "channel closed" failures.
final class ErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func record(_ error: Error) {
        lock.withLock { if self.error == nil { self.error = error } }
    }

    var first: Error? { lock.withLock { error } }
}

private final class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    let errors: ErrorRecorder

    init(errors: ErrorRecorder) { self.errors = errors }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        errors.record(error)
        context.close(promise: nil)
    }
}

/// One command: sends stdin then EOF, collects stdout, stderr and the exit status.
private final class ExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = Never
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let input: Data?
    private var done: EventLoopPromise<RemoteCommandResult>?
    private var stdout = Data()
    private var stderr = Data()
    private var status: Int32?

    init(command: String, input: Data?, done: EventLoopPromise<RemoteCommandResult>) {
        self.command = command
        self.input = input
        self.done = done
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelActive(context: ChannelHandlerContext) {
        let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(exec).whenFailure { [weak self] error in self?.finish(error: error) }
        context.fireChannelActive()
    }

    /// The command started: send its stdin, then EOF.
    private func sendInput(context: ChannelHandlerContext) {
        if let input, !input.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: input.count)
            buffer.writeBytes(input)
            context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
        }
        context.close(mode: .output, promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = message.data else { return }
        if message.type == .stdErr {
            stderr.append(contentsOf: bytes.readableBytesView)
        } else {
            stdout.append(contentsOf: bytes.readableBytesView)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            sendInput(context: context)
        case let exit as SSHChannelRequestEvent.ExitStatus:
            status = Int32(exit.exitStatus)
        case is SSHChannelRequestEvent.ExitSignal:
            status = 128
        case is ChannelFailureEvent:
            finish(error: BackendError(code: "internal", message: "the server refused to run the command"))
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finish()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(error: error)
        context.close(promise: nil)
    }

    private func finish(error: Error? = nil) {
        guard let done else { return }
        self.done = nil
        if let error {
            done.fail(error)
        } else {
            done.succeed(RemoteCommandResult(status: status ?? 255, stdout: String(decoding: stdout, as: UTF8.self),
                                             stderr: String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }
}

/// How a bridge command ended, read when its stream closes.
final class StreamStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var _exit: Int32?
    private var _stderr = Data()

    var exit: Int32? { lock.withLock { _exit } }
    var stderr: String {
        lock.withLock { String(decoding: _stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func setExit(_ code: Int32) { lock.withLock { _exit = code } }

    func appendStderr(_ bytes: ByteBufferView) {
        lock.withLock {
            _stderr.append(contentsOf: bytes)
            if _stderr.count > 4096 { _stderr = _stderr.suffix(4096) }
            if let text = String(data: Data(bytes), encoding: .utf8), text.contains("clothod: warning:") {
                log(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

/// The bridge's SSH side: runs the command, passes stdout bytes on as ByteBuffers (to the glue), wraps
/// outgoing bytes as channel data, and keeps stderr and the exit status for the close reason.
private final class BridgeHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let status: StreamStatus

    init(command: String, status: StreamStatus) {
        self.command = command
        self.status = status
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelActive(context: ChannelHandlerContext) {
        let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(exec).whenFailure { _ in context.close(promise: nil) }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = message.data else { return }
        if message.type == .stdErr {
            status.appendStderr(bytes.readableBytesView)
        } else {
            context.fireChannelRead(wrapInboundOut(bytes))
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let bytes = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(bytes))), promise: promise)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let exit as SSHChannelRequestEvent.ExitStatus:
            status.setExit(Int32(exit.exitStatus))
        case is SSHChannelRequestEvent.ExitSignal:
            status.setExit(128)
        case is ChannelFailureEvent:
            status.setExit(127)
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
}

/// Joins two channels on the same event loop, with backpressure (after swift-nio-ssh's NIOSSHClient example).
private final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler(), second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private var partnerWritable: Bool { context?.channel.isWritable ?? false }

    private func partnerBecameWritable() {
        guard pendingRead else { return }
        pendingRead = false
        context?.read()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.context?.write(data, promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.context?.flush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.context?.close(promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.context?.close(mode: .output, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.context?.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}
