package main

// End-to-end tests: real clothod-net and clothod processes against an in-process test control
// server (testctl), offline, in /tmp/clt* dirs with ephemeral clothod instances. Nothing here
// touches a real tailnet or the user's clothod.
//
// Binaries: $CLOTHOD_NET_BIN (else built from this package), $CLOTHOD_BIN (else
// ../target/debug/clothod or ../target/release/clothod; build it with `cargo build --bin clothod`).

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/ahmad/clotho/clothod/net/testctl"
	"tailscale.com/envknob"
	"tailscale.com/ipn/store/mem"
	"tailscale.com/net/netns"
	"tailscale.com/tsnet"
)

// releaseTags are the build tags scripts/build-net.sh builds with.
const releaseTags = "ts_omit_logtail"

var (
	netBin     string // clothod-net under test
	clothodBin string
)

func TestMain(m *testing.M) {
	os.Exit(func() int {
		// Everything these tests start inherits this (as clothod's own e2e tests do): test
		// instances end themselves, and never use the user's gh, claude or config.
		os.Setenv("CLOTHOD_EPHEMERAL", "60")
		os.Setenv("CLOTHOD_GH", "/nonexistent/gh")
		os.Setenv("CLOTHOD_SUMMARIZER", "/nonexistent/summarizer")
		os.Unsetenv("CLOTHOD_NET_CONTROL_URL")
		// In-process test nodes: no binding to the default interface (127.0.0.1 only), and no
		// port mappings on the LAN's router (the sidecars do the same as test instances).
		netns.SetEnabled(false)
		envknob.Setenv("TS_DISABLE_PORTMAPPER", "true")
		// ... and their backends' log dir somewhere temporary, not ~/.local/share/tailscale.
		logs, err := os.MkdirTemp("", "clothod-net-test-logs.")
		if err != nil {
			panic(err)
		}
		defer os.RemoveAll(logs)
		os.Setenv("TS_LOGS_DIR", logs)

		netBin = os.Getenv("CLOTHOD_NET_BIN")
		if netBin == "" {
			dir, err := os.MkdirTemp("", "clothod-net-test-bin.")
			if err != nil {
				panic(err)
			}
			defer os.RemoveAll(dir)
			netBin = filepath.Join(dir, "clothod-net")
			out, err := exec.Command("go", "build", "-tags", releaseTags, "-o", netBin, ".").CombinedOutput()
			if err != nil {
				fmt.Fprintf(os.Stderr, "building clothod-net: %v\n%s", err, out)
				return 1
			}
		}
		clothodBin = os.Getenv("CLOTHOD_BIN")
		if clothodBin == "" {
			for _, p := range []string{"../target/debug/clothod", "../target/release/clothod"} {
				if isExecutable(p) {
					clothodBin, _ = filepath.Abs(p)
					break
				}
			}
		}
		if clothodBin == "" {
			fmt.Fprintln(os.Stderr, "no clothod binary: set CLOTHOD_BIN or run `cargo build --bin clothod` in clothod/")
			return 1
		}
		return m.Run()
	}())
}

// instance is one test's /tmp/clt* dir: clothod's runtime dir (run/), its state (state/) and
// each node's state (<name>/).
type instance struct {
	t   *testing.T
	dir string
	ctl *testctl.Server
}

func newInstance(t *testing.T, opts testctl.Options) *instance {
	t.Helper()
	// Short: Unix socket paths are limited to ~104 bytes.
	dir, err := os.MkdirTemp("/tmp", "clt-net.")
	if err != nil {
		t.Fatal(err)
	}
	in := &instance{t: t, dir: dir}
	t.Cleanup(in.cleanup) // runs after the processes' cleanups (registered later, run first)
	if testing.Verbose() {
		opts.Logf = t.Logf
	}
	in.ctl, err = testctl.Start(t, opts)
	if err != nil {
		t.Fatal(err)
	}
	return in
}

func (in *instance) runDir() string { return filepath.Join(in.dir, "run") }

// env is the environment for processes of this instance: clothod stays inside the dir. Its
// XDG_DATA_HOME is the instance's too, where cleanup checks that clothod-net wrote nothing
// (tailscaled's default dirs live there), and TS_LOGS_DIR is left for clothod-net to set.
func (in *instance) env() []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "TS_LOGS_DIR=") {
			env = append(env, kv)
		}
	}
	return append(env,
		"XDG_DATA_HOME="+filepath.Join(in.dir, "xdg-data"),
		"CLOTHOD_STATE_DIR="+filepath.Join(in.dir, "state"),
		"CLOTHOD_RUNTIME_DIR="+in.runDir(),
		"CLOTHOD_REGISTRY_DIR="+filepath.Join(in.dir, "registry"),
		"CLOTHOD_CONFIG="+filepath.Join(in.dir, "config.toml"),
		"CLAUDE_CONFIG_DIR="+filepath.Join(in.dir, "claude-config"),
	)
}

// cleanup ends every process that serves this instance's dirs, then removes them.
func (in *instance) cleanup() {
	exec.Command(clothodBin, "shutdown", "--runtime-dir", in.runDir()).Run()
	deadline := time.Now().Add(5 * time.Second)
	sig := syscall.SIGTERM
	for {
		left := processesMentioning(in.dir)
		if len(left) == 0 {
			break
		}
		if time.Now().After(deadline) {
			sig = syscall.SIGKILL
		}
		for _, pid := range left {
			syscall.Kill(pid, sig)
		}
		if sig == syscall.SIGKILL {
			time.Sleep(100 * time.Millisecond)
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if _, err := os.Stat(filepath.Join(in.dir, "xdg-data", "tailscale")); err == nil {
		in.t.Errorf("clothod-net created tailscaled's default dir ($XDG_DATA_HOME/tailscale)")
	}
	os.RemoveAll(in.dir)
}

// processesMentioning lists this user's processes with s in their arguments (not this one).
func processesMentioning(s string) []int {
	out, _ := exec.Command("ps", "-o", "pid=,args=", "-U", strconv.Itoa(os.Getuid())).Output()
	var pids []int
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 || !strings.Contains(line, s) {
			continue
		}
		if pid, err := strconv.Atoi(f[0]); err == nil && pid != os.Getpid() {
			pids = append(pids, pid)
		}
	}
	return pids
}

// proc is a clothod-net process.
type proc struct {
	cmd  *exec.Cmd
	log  string
	done chan struct{}
	err  error
}

// start runs clothod-net with args (plus --control-url and --ephemeral), its stderr to
// <dir>/<name>.log.
func (in *instance) start(name string, stdin io.Reader, stdout io.Writer, args ...string) *proc {
	in.t.Helper()
	logPath := filepath.Join(in.dir, name+".log")
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		in.t.Fatal(err)
	}
	args = append(args, "--control-url", in.ctl.URL, "--ephemeral")
	cmd := exec.Command(netBin, args...)
	cmd.Env = in.env()
	cmd.Stdin, cmd.Stdout, cmd.Stderr = stdin, stdout, f
	if err := cmd.Start(); err != nil {
		in.t.Fatal(err)
	}
	f.Close()
	p := &proc{cmd: cmd, log: logPath, done: make(chan struct{})}
	go func() {
		p.err = cmd.Wait()
		close(p.done)
	}()
	in.t.Cleanup(func() {
		p.stop()
		if in.t.Failed() {
			b, _ := os.ReadFile(logPath)
			in.t.Logf("--- %s.log:\n%s", name, b)
		}
	})
	return p
}

func (p *proc) stop() {
	select {
	case <-p.done:
		return
	default:
	}
	p.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-p.done:
	case <-time.After(5 * time.Second):
		p.cmd.Process.Kill()
		<-p.done
	}
}

func (p *proc) exited() bool {
	select {
	case <-p.done:
		return true
	default:
		return false
	}
}

func (p *proc) logText() string {
	b, _ := os.ReadFile(p.log)
	return string(b)
}

// serveNode starts `clothod-net serve` for node name and waits until it runs.
func (in *instance) serveNode(name string, port int) (*proc, *nodeStatus) {
	in.t.Helper()
	p := in.start(name, nil, nil, "serve", "--port", strconv.Itoa(port),
		"--state-dir", filepath.Join(in.dir, name), "--hostname", name,
		"--clothod", clothodBin, "--runtime-dir", in.runDir())
	return p, in.waitRunning(p, name)
}

func (in *instance) stateOf(name string) *config {
	return &config{stateDir: filepath.Join(in.dir, name, "tailnet")}
}

func (in *instance) waitRunning(p *proc, name string) *nodeStatus {
	in.t.Helper()
	deadline := time.Now().Add(60 * time.Second)
	for {
		st, err := askStatus(in.stateOf(name))
		if err == nil && st.State == "Running" && len(st.IPs) > 0 && (st.Mode != "serve" || st.UpMS > 0) {
			return st
		}
		if p.exited() {
			in.t.Fatalf("%s exited: %v\n%s", name, p.err, p.logText())
		}
		if time.Now().After(deadline) {
			in.t.Fatalf("%s not Running after 60s (status %+v, %v)\n%s", name, st, err, p.logText())
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// tsnetNode is an in-process test node (ephemeral, in-memory state) on the test tailnet.
func (in *instance) tsnetNode(t *testing.T, hostname string, tags ...string) *tsnet.Server {
	t.Helper()
	s := &tsnet.Server{
		Dir:           filepath.Join(in.dir, hostname),
		Hostname:      hostname,
		ControlURL:    in.ctl.URL,
		Store:         new(mem.Store),
		Ephemeral:     true,
		AdvertiseTags: tags,
		UserLogf:      func(string, ...any) {},
	}
	t.Cleanup(func() { s.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if _, err := s.Up(ctx); err != nil {
		t.Fatalf("%s: %v", hostname, err)
	}
	return s
}

// dialFrom connects from s to addr, retrying while s doesn't know the peer yet.
func dialFrom(t *testing.T, s *tsnet.Server, addr string) net.Conn {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		c, err := s.Dial(ctx, "tcp", addr)
		cancel()
		if err == nil {
			return c
		}
		if time.Now().After(deadline) {
			t.Fatalf("dial %s: %v", addr, err)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// hello does the protocol handshake on rw and returns the result (docs/protocol.md).
func hello(rw io.ReadWriter, timeout time.Duration) (map[string]any, error) {
	if c, ok := rw.(net.Conn); ok {
		c.SetDeadline(time.Now().Add(timeout))
		defer c.SetDeadline(time.Time{})
	}
	if err := writeJSON(rw, map[string]any{"id": 1, "method": "hello", "params": map[string]any{"protocol": 1, "client": "clothod-net-test/0"}}); err != nil {
		return nil, err
	}
	for {
		msg, err := readJSON(rw)
		if err != nil {
			return nil, err
		}
		if id, ok := msg["id"].(float64); ok && id == 1 {
			if e, ok := msg["error"]; ok {
				return nil, fmt.Errorf("hello: %v", e)
			}
			res, _ := msg["result"].(map[string]any)
			return res, nil
		}
	}
}

func writeJSON(w io.Writer, v any) error {
	body, _ := json.Marshal(v)
	frame := make([]byte, 5, 5+len(body))
	binary.BigEndian.PutUint32(frame, uint32(1+len(body)))
	frame[4] = 1 // JSON
	_, err := w.Write(append(frame, body...))
	return err
}

// readJSON reads frames until a JSON one, skipping the others.
func readJSON(r io.Reader) (map[string]any, error) {
	for {
		var hdr [5]byte
		if _, err := io.ReadFull(r, hdr[:]); err != nil {
			return nil, err
		}
		n := binary.BigEndian.Uint32(hdr[:4])
		if n == 0 || n > 16<<20 {
			return nil, fmt.Errorf("bad frame length %d", n)
		}
		body := make([]byte, n-1)
		if _, err := io.ReadFull(r, body); err != nil {
			return nil, err
		}
		if hdr[4] != 1 {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal(body, &m); err != nil {
			return nil, err
		}
		return m, nil
	}
}

// pipeConn is the dialer process's stdio as one ReadWriter.
type pipeConn struct {
	io.Reader
	io.WriteCloser
}

// dialProc runs `clothod-net dial` as node name and returns its stdio.
func (in *instance) dialProc(name, target string) (*proc, *pipeConn) {
	in.t.Helper()
	// OS pipes, so its stdio needs no copying goroutines (which cmd.Wait would wait on): the
	// test's ends see EOF when it exits.
	inR, inW, err := os.Pipe()
	if err != nil {
		in.t.Fatal(err)
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		in.t.Fatal(err)
	}
	p := in.start(name, inR, outW, "dial", target, "--state-dir", filepath.Join(in.dir, name), "--hostname", name)
	inR.Close()
	outW.Close()
	in.t.Cleanup(func() {
		inW.Close()
		outR.Close()
	})
	return p, &pipeConn{Reader: outR, WriteCloser: inW}
}

func servePID(t *testing.T, res map[string]any) int {
	t.Helper()
	pid, ok := res["pid"].(float64)
	if !ok || res["daemon"] != "clothod" {
		t.Fatalf("not a clothod hello reply: %v", res)
	}
	return int(pid)
}

// Sidecar A fronts an ephemeral clothod; sidecar B, in dial mode, pipes its stdio to it and a
// protocol hello succeeds. Then serve is killed, and the next dial still works (A starts serve
// again); A itself stays up throughout.
func TestDialHelloSurvivesServeRestart(t *testing.T) {
	in := newInstance(t, testctl.Options{})
	const port = 7400
	t0 := time.Now()
	a, st := in.serveNode("clothod-a", port)
	t.Logf("A Running after %v (%d ms from its start)", time.Since(t0), st.UpMS)
	target := net.JoinHostPort(st.IPs[0], strconv.Itoa(port))

	t0 = time.Now()
	b, conn := in.dialProc("dialer-b", target)
	res, err := hello(conn, 60*time.Second)
	if err != nil {
		t.Fatalf("hello through the sidecars: %v\nA:\n%s\nB:\n%s", err, a.logText(), b.logText())
	}
	t.Logf("hello through a new dialer (join, dial, start clothod, hello): %v", time.Since(t0))
	pid1 := servePID(t, res)
	conn.Close() // stdin EOF: the dialer exits 0
	select {
	case <-b.done:
		if b.err != nil {
			t.Fatalf("dialer exited with %v", b.err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("dialer did not exit after stdin closed")
	}

	// Kill serve (the holder keeps running); the next connection must start it again.
	if err := syscall.Kill(pid1, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	for syscall.Kill(pid1, 0) == nil {
		time.Sleep(20 * time.Millisecond)
	}
	t0 = time.Now()
	c2, conn2 := in.dialProc("dialer-c", target)
	res2, err := hello(conn2, 60*time.Second)
	if err != nil {
		t.Fatalf("hello after serve was killed: %v\nA:\n%s", err, a.logText())
	}
	t.Logf("hello after serve was killed (join, dial, restart serve, hello): %v", time.Since(t0))
	if pid2 := servePID(t, res2); pid2 == pid1 {
		t.Fatalf("same serve pid %d after it was killed", pid2)
	}
	if a.exited() {
		t.Fatalf("sidecar A exited: %v", a.err)
	}
	if !strings.Contains(a.logText(), "started clothod") {
		t.Errorf("A's log doesn't say it started clothod:\n%s", a.logText())
	}

	// SIGTERM stops A promptly and cleanly, with a client still connected, and the client sees
	// the connection end.
	a.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-a.done:
		if a.err != nil {
			t.Errorf("A exited with %v after SIGTERM:\n%s", a.err, a.logText())
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("A still running 5 s after SIGTERM with a client connected:\n%s", a.logText())
	}
	ended := make(chan struct{})
	go func() {
		for {
			if _, err := readJSON(conn2); err != nil {
				close(ended)
				return
			}
		}
	}()
	select {
	case <-ended:
	case <-time.After(10 * time.Second):
		ps, _ := exec.Command("ps", "-o", "pid,stat,args", "-p", strconv.Itoa(c2.cmd.Process.Pid)).Output()
		t.Errorf("the connection through A is still open 10 s after A stopped (dialer exited %v: %v)\n%s", c2.exited(), c2.err, ps)
	}
	conn2.Close()
}

// The peer check: a device of the same user gets in; a second user's device, a tagged node and
// a node shared in from another tailnet are closed before a reply, and A logs why.
func TestPeerCheck(t *testing.T) {
	in := newInstance(t, testctl.Options{})
	const port = 7401
	a, st := in.serveNode("clothod-a", port) // the first node: user A
	target := net.JoinHostPort(st.IPs[0], strconv.Itoa(port))

	cases := []struct {
		host   string
		tags   []string
		allow  bool
		reason string
	}{
		{host: "laptop-same-user", allow: true},
		{host: testctl.OtherUserPrefix + "laptop", reason: "another user's device"},
		{host: "tagged-by-advertising", tags: []string{"tag:clotho-test"}, reason: "tagged peer"},
		{host: testctl.TaggedPrefix + "server", reason: "tagged peer"},
		{host: testctl.SharedPrefix + "laptop", reason: "shared in"},
	}
	var wg sync.WaitGroup
	for _, c := range cases {
		wg.Add(1)
		go func() {
			defer wg.Done()
			t.Run(c.host, func(t *testing.T) {
				s := in.tsnetNode(t, c.host, c.tags...)
				conn := dialFrom(t, s, target)
				defer conn.Close()
				res, err := hello(conn, 30*time.Second)
				if c.allow {
					if err != nil {
						t.Fatalf("same user refused: %v\n%s", err, a.logText())
					}
					servePID(t, res)
					return
				}
				if err == nil {
					t.Fatalf("%s got a hello reply: %v", c.host, res)
				}
				if ne, ok := err.(net.Error); ok && ne.Timeout() {
					t.Fatalf("%s: connection left open, not closed: %v", c.host, err)
				}
			})
		}()
	}
	wg.Wait()
	log := a.logText()
	for _, c := range cases {
		if c.allow {
			continue
		}
		if !strings.Contains(log, c.reason) {
			t.Errorf("A's log has no %q (for %s):\n%s", c.reason, c.host, log)
		}
	}
	if n := strings.Count(log, "refused "); n != len(cases)-1 {
		t.Errorf("A refused %d connections, want %d:\n%s", n, len(cases)-1, log)
	}
}

// login prints the sign-in URL and waits; visiting it signs the node in. status then reports
// the node (starting it from its state), serve owns it, and a second process can't.
func TestLoginStatusAndLock(t *testing.T) {
	in := newInstance(t, testctl.Options{RequireAuth: true})
	outR, outW := io.Pipe()
	login := in.start("login", nil, outW, "login", "--state-dir", filepath.Join(in.dir, "node"), "--hostname", "clothod-l", "--timeout", "60s")
	go func() { <-login.done; outW.Close() }()
	sc := bufio.NewScanner(outR)
	var lines []string
	visited := false
	for sc.Scan() {
		line := sc.Text()
		lines = append(lines, line)
		if u, ok := strings.CutPrefix(line, "auth_url="); ok && !visited {
			if !strings.HasPrefix(u, in.ctl.URL+"/auth/") {
				t.Fatalf("auth URL %q is not the test control's", u)
			}
			res, err := http.Get(u) // the browser visit
			if err != nil || res.StatusCode != 200 {
				t.Fatalf("visiting %s: %v %v", u, err, res)
			}
			res.Body.Close()
			visited = true
		}
	}
	<-login.done
	if login.err != nil || !visited || !contains(lines, "state=Running") {
		t.Fatalf("login: %v, output %q\n%s", login.err, lines, login.logText())
	}

	// Nobody runs the node: status starts it from its state (no new sign-in) and says so.
	out, err := in.run("status", "--state-dir", filepath.Join(in.dir, "node"), "--hostname", "clothod-l")
	if err != nil {
		t.Fatalf("status: %v\n%s", err, out)
	}
	var st nodeStatus
	if err := json.Unmarshal(out, &st); err != nil {
		t.Fatalf("status output: %v\n%s", err, out)
	}
	if st.Running || st.State != "Running" || st.User == nil || len(st.IPs) == 0 || st.ControlURL != in.ctl.URL || !st.Test || st.Ephemeral {
		t.Fatalf("status of a signed-in, stopped node: %s", out)
	}

	// serve owns it: status asks serve; login has nothing to do; a second serve is refused.
	srv := in.start("node", nil, nil, "serve", "--port", "7402", "--state-dir", filepath.Join(in.dir, "node"),
		"--hostname", "clothod-l", "--clothod", clothodBin, "--runtime-dir", in.runDir())
	in.waitRunning(srv, "node")
	out, err = in.run("status", "--state-dir", filepath.Join(in.dir, "node"))
	if err != nil || json.Unmarshal(out, &st) != nil || !st.Running || st.Mode != "serve" || st.Listen != ":7402" || st.UpMS <= 0 {
		t.Fatalf("status while serving: %v\n%s", err, out)
	}
	out, err = in.run("login", "--state-dir", filepath.Join(in.dir, "node"), "--timeout", "10s")
	if err != nil || !strings.Contains(string(out), "state=Running") || strings.Contains(string(out), "auth_url") {
		t.Fatalf("login while serving: %v\n%s", err, out)
	}
	out, err = in.run("serve", "--port", "7403", "--state-dir", filepath.Join(in.dir, "node"), "--clothod", clothodBin, "--runtime-dir", in.runDir())
	if err == nil || !strings.Contains(string(out), "another clothod-net") {
		t.Fatalf("a second serve on the same state: %v\n%s", err, out)
	}
	// The state dir is private.
	if fi, err := os.Stat(filepath.Join(in.dir, "node", "tailnet")); err != nil || fi.Mode().Perm() != 0o700 {
		t.Fatalf("state dir mode: %v %v", fi.Mode(), err)
	}
}

// run runs clothod-net to completion (with the test control URL and --ephemeral), returning
// stdout, plus stderr on failure.
func (in *instance) run(args ...string) ([]byte, error) {
	args = append(args, "--control-url", in.ctl.URL, "--ephemeral")
	cmd := exec.Command(netBin, args...)
	cmd.Env = in.env()
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	timer := time.AfterFunc(60*time.Second, func() { cmd.Process.Kill() })
	defer timer.Stop()
	out, err := cmd.Output()
	if err != nil {
		return append(out, stderr.Bytes()...), err
	}
	return out, nil
}

func contains(lines []string, s string) bool {
	for _, l := range lines {
		if l == s {
			return true
		}
	}
	return false
}

// A test instance never joins a real tailnet: without a test control URL, or without its own
// state dir, it refuses to start (before any network use).
func TestTestInstanceNeedsTestControl(t *testing.T) {
	dir := t.TempDir()
	for _, tc := range []struct {
		args []string
		env  string
		want string
	}{
		{[]string{"serve", "--port", "1", "--ephemeral", "--state-dir", dir}, "", "--control-url"},
		{[]string{"status", "--state-dir", dir}, "CLOTHOD_EPHEMERAL=60", "--control-url"},
		{[]string{"login", "--ephemeral", "--control-url", "http://127.0.0.1:9"}, "", "--state-dir"},
		{[]string{"dial", "x:1", "--ephemeral"}, "", "--control-url"},
		{[]string{"serve", "--port", "1", "--state-dir", dir, "--control-url", "https://controlplane.tailscale.com"}, "CLOTHOD_EPHEMERAL=exit", "on this machine"},
		{[]string{"status", "--ephemeral", "--state-dir", dir}, "CLOTHOD_NET_CONTROL_URL=http://192.0.2.1:80", "on this machine"},
	} {
		cmd := exec.Command(netBin, tc.args...)
		cmd.Env = append(os.Environ(), "CLOTHOD_EPHEMERAL=", "CLOTHOD_NET_CONTROL_URL=")
		if tc.env != "" {
			cmd.Env = append(cmd.Env, tc.env)
		}
		out, err := cmd.CombinedOutput()
		if err == nil || !strings.Contains(string(out), tc.want) {
			t.Errorf("%v (%s): want a refusal naming %s, got %v: %s", tc.args, tc.env, tc.want, err, out)
		}
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Errorf("a refused instance left state behind: %v", entries)
	}
}

// An ephemeral node logs out when it exits, so dial and --ephemeral-node never run in the
// machine's node dir, and neither does a test instance. HOME points at a scratch dir here, so a
// failure touches only that.
func TestEphemeralNodeNeverUsesMachineNode(t *testing.T) {
	home := t.TempDir()
	machine := filepath.Join(home, ".local", "state", "clothod")
	if runtime.GOOS == "darwin" {
		machine = filepath.Join(home, "Library", "Application Support", "clothod")
	}
	other := t.TempDir()
	for _, tc := range []struct {
		args []string
		env  string
		want string
	}{
		{[]string{"dial", "x:1"}, "", "--state-dir"},
		{[]string{"dial", "x:1", "--timeout", "1s"}, "CLOTHOD_STATE_DIR=" + other, "--state-dir"},
		{[]string{"dial", "x:1", "--state-dir", machine}, "", "machine's own node"},
		{[]string{"status", "--ephemeral-node"}, "", "--state-dir"},
		{[]string{"serve", "--port", "1", "--ephemeral-node", "--state-dir", machine + "/"}, "", "machine's own node"},
		{[]string{"status", "--ephemeral", "--control-url", "http://127.0.0.1:9", "--state-dir", machine}, "", "machine's own node"},
	} {
		cmd := exec.Command(netBin, tc.args...)
		cmd.Env = append(os.Environ(), "HOME="+home, "XDG_STATE_HOME=", "CLOTHOD_STATE_DIR=",
			"CLOTHOD_EPHEMERAL=", "CLOTHOD_NET_CONTROL_URL=")
		if tc.env != "" {
			cmd.Env = append(cmd.Env, tc.env)
		}
		out, err := cmd.CombinedOutput()
		if err == nil || !strings.Contains(string(out), tc.want) {
			t.Errorf("%v (%s): want a refusal naming %s, got %v: %s", tc.args, tc.env, tc.want, err, out)
		}
	}
	for _, d := range []string{home, other} {
		if entries, _ := os.ReadDir(d); len(entries) != 0 {
			t.Errorf("a refused node left state in %s: %v", d, entries)
		}
	}
}

func rssKB(pid int) int {
	out, err := exec.Command("ps", "-o", "rss=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return -1
	}
	n, _ := strconv.Atoi(strings.TrimSpace(string(out)))
	return n
}

// Measurements for the Phase 0 report (CLOTHOD_NET_MEASURE=1): time to Running on a first join
// and on a restart with existing state, idle RSS, and RSS after 100 dials (each a hello).
func TestMeasure(t *testing.T) {
	if os.Getenv("CLOTHOD_NET_MEASURE") == "" {
		t.Skip("set CLOTHOD_NET_MEASURE=1")
	}
	in := newInstance(t, testctl.Options{})
	const port = 7404
	a, st := in.serveNode("clothod-m", port)
	t.Logf("MEASURE first join: %d ms from process start to Running", st.UpMS)
	a.stop()
	a, st = in.serveNode("clothod-m", port)
	t.Logf("MEASURE restart with existing state: %d ms from process start to Running", st.UpMS)
	time.Sleep(5 * time.Second)
	t.Logf("MEASURE idle RSS: %d KiB (%s/%s)", rssKB(a.cmd.Process.Pid), runtime.GOOS, runtime.GOARCH)

	s := in.tsnetNode(t, "dialer-m")
	target := net.JoinHostPort(st.IPs[0], strconv.Itoa(port))
	var took []time.Duration
	for i := 0; i < 100; i++ {
		t0 := time.Now()
		c := dialFrom(t, s, target)
		if _, err := hello(c, 30*time.Second); err != nil {
			t.Fatalf("dial %d: %v", i, err)
		}
		c.Close()
		took = append(took, time.Since(t0))
	}
	// The first includes the dialer finding A, and A starting clothod.
	rest := slices.Clone(took[1:])
	slices.Sort(rest)
	t.Logf("MEASURE 100 dials, each connect + hello + close: first %v; the other 99: median %v, p95 %v, max %v",
		took[0].Round(time.Millisecond), rest[49].Round(100*time.Microsecond), rest[93].Round(100*time.Microsecond), rest[98].Round(100*time.Microsecond))
	time.Sleep(2 * time.Second)
	t.Logf("MEASURE RSS after 100 dials: %d KiB", rssKB(a.cmd.Process.Pid))
}
