# Creates a workspace on the iOS dev clothod (/tmp/cki-ios) and runs a stand-in agent in it that reports
# `waiting` through `clothod report` and stays alive for 5 minutes. For ClothoUITests/RealAgentUITests.
import json, socket, struct, sys, time
s = socket.socket(socket.AF_UNIX); s.connect("/tmp/cki-ios/clothod.sock")
buf = b""
def send(i, m, p=None):
    o = {"id": i, "method": m}
    if p is not None: o["params"] = p
    b = json.dumps(o).encode(); s.sendall(struct.pack(">IB", len(b) + 1, 1) + b)
def reply(i):
    global buf
    while True:
        while len(buf) >= 4:
            n = struct.unpack(">I", buf[:4])[0]
            if len(buf) < 4 + n: break
            t, body = buf[4], buf[5:4 + n]; buf = buf[4 + n:]
            if t == 1:
                o = json.loads(body)
                if o.get("id") == i: return o
        buf += s.recv(65536)
send(1, "hello", {"protocol": 1, "client": "ios-agent-check"}); reply(1)
send(2, "workspace.create", {"name": sys.argv[1] if len(sys.argv) > 1 else "agents"}); pane = reply(2)["result"]["pane"]
time.sleep(1)
send(3, "pane.input", {"pane": pane, "data": 'sh -c \'/tmp/cki-ios-bin/clothod report waiting --agent claude --message "Allow cargo test --release?"; sleep 300\'\r'}); reply(3)
time.sleep(1.5)
send(4, "state.get"); st = reply(4)["result"]
print(pane, [p.get("agent") for p in st["panes"] if p["id"] == pane])
