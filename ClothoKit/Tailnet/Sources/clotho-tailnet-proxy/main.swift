// clotho-tailnet-proxy: ssh's ProxyCommand for connections over Clotho's own tailnet node.
//
//   ssh -o ProxyUseFdpass=yes -o "ProxyCommand='<path>/clotho-tailnet-proxy' --socket '<node dir>/proxy.sock' %h %p" ...
//
// It asks the app (TailnetProxyServer, on a 0600 socket in the node's 0700 dir) to dial HOST:PORT over the
// tailnet, receives the connected descriptor, and passes it to ssh over stdout (ProxyUseFdpass), then exits:
// ssh talks to the connection directly, and no bytes go through this process.
//
// It has its own deadline (--timeout, default 10 s, the app's ssh ConnectTimeout): ssh's ConnectTimeout doesn't
// bound a ProxyUseFdpass handoff. On any failure it prints `clotho-tailnet-proxy: <why>` to stderr and exits 255,
// as ssh does when it can't connect.
import Darwin
import TailnetFdPass

func fail(_ message: String) -> Never {
    let line = "clotho-tailnet-proxy: \(message)\n"
    _ = line.withCString { tfp_write_all(2, $0, strlen($0)) }
    exit(255)
}

func errnoText() -> String { String(cString: strerror(errno)) }

var socketPath: String?
var timeout = 10.0
var positional: [String] = []
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--socket": socketPath = args.popFirst()
    case "--timeout":
        guard let value = args.popFirst().flatMap(Double.init), value > 0 else { fail("--timeout needs a number of seconds") }
        timeout = value
    case "-h", "--help":
        print("usage: clotho-tailnet-proxy --socket PATH [--timeout SECS] HOST PORT")
        exit(0)
    default: positional.append(arg)
    }
}
guard let socketPath, positional.count == 2, let port = Int(positional[1]), (1...65535).contains(port),
      !positional[0].isEmpty, !positional[0].contains(where: { $0 == " " || $0 == "\n" }) else {
    fail("usage: clotho-tailnet-proxy --socket PATH [--timeout SECS] HOST PORT")
}
let host = positional[0]
let deadline = Int32(timeout * 1000)

let sock = tfp_connect(socketPath)
guard sock >= 0 else { fail("can't reach Clotho's tailnet node at \(socketPath): \(errnoText()) (is Clotho running with its tailnet on?)") }
let request = "\(host) \(port)\n"
guard request.withCString({ tfp_write_all(sock, $0, strlen($0)) }) == 0 else { fail("writing to \(socketPath): \(errnoText())") }

var reply = [CChar](repeating: 0, count: 512)
let fd = tfp_recv_fd(sock, deadline, &reply, reply.count)
switch fd {
case -2:
    var text = String(cString: reply).trimmingTrailingNewlines()
    if text.hasPrefix("error ") { text.removeFirst(6) }
    fail("\(host):\(port): \(text)")
case ..<0:
    if errno == ETIMEDOUT { fail("\(host):\(port): no connection after \(timeout) s") }
    fail("\(host):\(port): \(errno == ECONNRESET ? "Clotho closed the request" : errnoText())")
default:
    guard tfp_send_fd(1, fd) == 0 else { fail("passing the connection to ssh: \(errnoText()) (needs ProxyUseFdpass=yes)") }
    exit(0)
}

extension String {
    func trimmingTrailingNewlines() -> String {
        var s = self
        while s.last == "\n" || s.last == "\r" { s.removeLast() }
        return s
    }
}
