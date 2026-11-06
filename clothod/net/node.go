package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/envknob"
	"tailscale.com/ipn"
	"tailscale.com/net/netns"
	"tailscale.com/tsnet"
)

// config is what every command resolves its flags and environment to.
type config struct {
	stateDir      string // the node's own dir: <state dir>/tailnet
	controlURL    string // "" = Tailscale's
	hostname      string
	ephemeralArg  string // passed on to clothod as --ephemeral=<v>; "" = not a test instance (or set by env)
	test          bool   // a test instance (--ephemeral or $CLOTHOD_EPHEMERAL)
	ephemeralNode bool   // register an ephemeral node
	verbose       bool
}

// config applies the defaults and the safety rules:
//   - A test instance (--ephemeral or $CLOTHOD_EPHEMERAL) only ever joins a test control server
//     given with --control-url (or $CLOTHOD_NET_CONTROL_URL), never Tailscale's, and needs its
//     own --state-dir, never the machine's.
func (c *commonFlags) config() (*config, error) {
	cfg := &config{verbose: c.verbose}
	envEph := os.Getenv("CLOTHOD_EPHEMERAL")
	test := c.ephemeral.set || envEph != ""
	if c.ephemeral.set {
		cfg.ephemeralArg = c.ephemeral.v
	}
	cfg.test = test
	cfg.ephemeralNode = c.ephNode
	if test {
		// Test nodes stay on this machine: no NAT-PMP/PCP/UPnP mappings on the LAN's router
		// (and so no public endpoints). Real nodes keep the port mapper for NAT traversal.
		envknob.Setenv("TS_DISABLE_PORTMAPPER", "true")
		// And no binding of the node's UDP socket to the default interface: on Linux that
		// drops its STUN to the test server on 127.0.0.1, and netcheck then waits 3 s for
		// nothing. Tailscale's own tests turn it off the same way.
		netns.SetEnabled(false)
	}
	cfg.controlURL = c.controlURL
	if cfg.controlURL == "" {
		cfg.controlURL = os.Getenv("CLOTHOD_NET_CONTROL_URL")
	}
	base := c.stateDir
	if test {
		if !isLoopbackURL(cfg.controlURL) {
			return nil, fmt.Errorf("a test instance (--ephemeral or CLOTHOD_EPHEMERAL) never joins a real tailnet: give it a test control server on this machine with --control-url (got %q)", cfg.controlURL)
		}
		if base == "" {
			return nil, errors.New("a test instance (--ephemeral or CLOTHOD_EPHEMERAL) needs its own --state-dir")
		}
	}
	if base == "" {
		base = defaultStateDir()
	}
	abs, err := filepath.Abs(base)
	if err != nil {
		return nil, err
	}
	cfg.stateDir = filepath.Join(abs, "tailnet")
	cfg.hostname = c.hostname
	if cfg.hostname == "" {
		cfg.hostname = defaultHostname(devBuild != "" || test)
	}
	return cfg, nil
}

// isLoopbackURL: an http(s) URL whose host is a loopback address or localhost.
func isLoopbackURL(s string) bool {
	u, err := url.Parse(s)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
		return false
	}
	h := u.Hostname()
	if h == "localhost" {
		return true
	}
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}

// defaultStateDir is clothod's state dir (proto/src/platform: state_dir): $CLOTHOD_STATE_DIR,
// else ~/Library/Application Support/clothod on macOS, $XDG_STATE_HOME/clothod or
// ~/.local/state/clothod elsewhere.
func defaultStateDir() string {
	if d := os.Getenv("CLOTHOD_STATE_DIR"); d != "" {
		return d
	}
	home, _ := os.UserHomeDir()
	if runtime.GOOS == "darwin" {
		return filepath.Join(home, "Library", "Application Support", "clothod")
	}
	if d := os.Getenv("XDG_STATE_HOME"); d != "" {
		return filepath.Join(d, "clothod")
	}
	return filepath.Join(home, ".local", "state", "clothod")
}

// defaultHostname is clothod-<host> (PLAN decision 7), from the first label of the OS hostname,
// lowercased, with anything but [a-z0-9-] made a '-'.
func defaultHostname(dev bool) string {
	h, _ := os.Hostname()
	h, _, _ = strings.Cut(strings.ToLower(h), ".")
	h = strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-' {
			return r
		}
		return '-'
	}, h)
	h = strings.Trim(h, "-")
	if h == "" {
		h = "machine"
	}
	name := "clothod-" + h
	if dev {
		name += "-dev"
	}
	return name
}

// node is the tsnet node and the state dir this process owns.
type node struct {
	cfg  *config
	mode string // the command running it: serve, login, status, dial
	lock *os.File
	srv  *tsnet.Server
	lc   *local.Client
	api  *http.Server // the status socket
	// serve only, reported by status
	listen string
	upMS   int64
	// serve: a connection was closed because the process is stopping
	cutShort atomic.Bool
}

// openNode takes ownership of the state dir: creates it 0700 (refusing one that isn't ours) and
// locks it, so only one process at a time runs this node.
func openNode(cfg *config, mode string) (*node, error) {
	if err := ensurePrivateDir(cfg.stateDir); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(cfg.stateDir, "lock"), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		b := make([]byte, 64)
		k, _ := f.ReadAt(b, 0)
		f.Close()
		owner := strings.TrimSpace(string(b[:k]))
		return nil, fmt.Errorf("another clothod-net (%s) runs the node in %s", owner, cfg.stateDir)
	}
	f.Truncate(0)
	f.WriteAt([]byte(fmt.Sprintf("pid %d, %s\n", os.Getpid(), mode)), 0)
	// The node's own files stay in its dir: without this, the backend (its socket stats
	// logger) creates tailscaled's default log dir, ~/.local/share/tailscale.
	os.Setenv("TS_LOGS_DIR", cfg.stateDir)
	n := &node{cfg: cfg, mode: mode, lock: f}
	n.srv = &tsnet.Server{
		Dir:        cfg.stateDir,
		Hostname:   cfg.hostname,
		ControlURL: cfg.controlURL,
		Ephemeral:  cfg.ephemeralNode,
		// tsnet's own messages (the auth URL hint names TS_AUTHKEY, which we don't use): only
		// with -v. Ours say the same in our words.
		UserLogf: func(format string, a ...any) {
			if cfg.verbose {
				log.Printf("tsnet: "+format, a...)
			}
		},
	}
	if n.srv.ControlURL == "" {
		// Explicit, so $TS_CONTROL_URL in the environment can't move a real node elsewhere.
		n.srv.ControlURL = ipn.DefaultControlURL
	}
	if cfg.verbose {
		n.srv.Logf = func(format string, a ...any) { log.Printf("node: "+format, a...) }
	}
	return n, nil
}

func ensurePrivateDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	fi, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !fi.IsDir() || !ok || int(st.Uid) != os.Getuid() {
		return fmt.Errorf("%s is not a directory owned by uid %d; refusing to use it", dir, os.Getuid())
	}
	return os.Chmod(dir, 0o700)
}

// start starts the node (without waiting for it to run) and the status socket.
func (n *node) start() error {
	if err := n.srv.Start(); err != nil {
		return fmt.Errorf("starting the node: %w", err)
	}
	lc, err := n.srv.LocalClient()
	if err != nil {
		return err
	}
	n.lc = lc
	return n.serveAPI()
}

func (n *node) socketPath() string { return filepath.Join(n.cfg.stateDir, "net.sock") }

// serveAPI answers GET /status on <state>/tailnet/net.sock (the dir is 0700), so `status` and
// `login` can ask the process that owns the node.
func (n *node) serveAPI() error {
	path := n.socketPath()
	os.Remove(path) // stale: we hold the lock
	ln, err := net.Listen("unix", path)
	if err != nil {
		return fmt.Errorf("status socket: %w", err)
	}
	os.Chmod(path, 0o600)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(n.status(r.Context()))
	})
	n.api = &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go n.api.Serve(ln)
	return nil
}

// askStatus asks the process that runs the node, if any.
func askStatus(cfg *config) (*nodeStatus, error) {
	path := filepath.Join(cfg.stateDir, "net.sock")
	c := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", path)
		}},
	}
	res, err := c.Get("http://clothod-net/status")
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status: %s", res.Status)
	}
	var st nodeStatus
	if err := json.NewDecoder(res.Body).Decode(&st); err != nil {
		return nil, err
	}
	return &st, nil
}

// nodeStatus is what `status` prints (JSON).
type nodeStatus struct {
	Running    bool       `json:"running"` // a clothod-net process runs the node (else status started it to look)
	PID        int        `json:"pid,omitempty"`
	Mode       string     `json:"mode,omitempty"` // serve, login or dial
	State      string     `json:"state"`          // NoState, NeedsLogin, NeedsMachineAuth, Stopped, Starting, Running
	AuthURL    string     `json:"auth_url,omitempty"`
	Hostname   string     `json:"hostname"`
	DNSName    string     `json:"dns_name,omitempty"`
	IPs        []string   `json:"ips,omitempty"`
	User       *userInfo  `json:"user,omitempty"`
	Tags       []string   `json:"tags,omitempty"`
	KeyExpiry  *time.Time `json:"key_expiry,omitempty"`
	Listen     string     `json:"listen,omitempty"` // serve: the tailnet port it accepts on, ":N"
	UpMS       int64      `json:"up_ms,omitempty"`  // serve: from process start to Running
	ControlURL string     `json:"control_url"`
	Test       bool       `json:"test_instance"`
	Ephemeral  bool       `json:"ephemeral_node"`
	StateDir   string     `json:"state_dir"`
	Version    string     `json:"version"`
	Tailscale  string     `json:"tailscale"`
	Error      string     `json:"error,omitempty"`
}

type userInfo struct {
	ID          int64  `json:"id"`
	LoginName   string `json:"login_name"`
	DisplayName string `json:"display_name,omitempty"`
}

// settled: a state that won't change by itself soon.
func (s *nodeStatus) settled() bool {
	switch s.State {
	case "Running", "NeedsMachineAuth", "Stopped":
		return true
	case "NeedsLogin":
		return s.AuthURL != ""
	}
	return false
}

func (n *node) status(ctx context.Context) *nodeStatus {
	out := &nodeStatus{
		Running:    true,
		PID:        os.Getpid(),
		Mode:       n.mode,
		Hostname:   n.cfg.hostname,
		ControlURL: n.srv.ControlURL,
		Test:       n.cfg.test,
		Ephemeral:  n.cfg.ephemeralNode,
		StateDir:   n.cfg.stateDir,
		Version:    version,
		Tailscale:  tailscaleVersion(),
		Listen:     n.listen,
		UpMS:       n.upMS,
	}
	st, err := n.lc.StatusWithoutPeers(ctx)
	if err != nil {
		out.State = "NoState"
		out.Error = err.Error()
		return out
	}
	out.State = st.BackendState
	out.AuthURL = st.AuthURL
	if self := st.Self; self != nil {
		out.DNSName = strings.TrimSuffix(self.DNSName, ".")
		for _, ip := range self.TailscaleIPs {
			out.IPs = append(out.IPs, ip.String())
		}
		if self.Tags != nil {
			out.Tags = self.Tags.AsSlice()
		}
		out.KeyExpiry = self.KeyExpiry
		if self.UserID != 0 {
			u := &userInfo{ID: int64(self.UserID)}
			if p, ok := st.User[self.UserID]; ok {
				u.LoginName, u.DisplayName = p.LoginName, p.DisplayName
			}
			out.User = u
		}
	}
	return out
}

// close stops the node and releases the state dir.
func (n *node) close() {
	if n.api != nil {
		n.api.Close()
		os.Remove(n.socketPath())
	}
	if n.lc != nil {
		n.srv.Close()
	}
	n.lock.Close()
}

// dial joins and connects to target over the tailnet, retrying until timeout while the peer
// isn't in the netmap or reachable yet.
func (n *node) dial(ctx context.Context, target string, timeout time.Duration) (net.Conn, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	if err := n.start(); err != nil {
		return nil, err
	}
	if _, err := n.srv.Up(ctx); err != nil {
		return nil, fmt.Errorf("joining: %w (state %s)", err, n.status(context.Background()).State)
	}
	var last error
	for {
		dctx, dcancel := context.WithTimeout(ctx, 5*time.Second)
		c, err := n.srv.Dial(dctx, "tcp", target)
		dcancel()
		if err == nil {
			return c, nil
		}
		last = err
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("dialing %s: %w", target, last)
		case <-time.After(200 * time.Millisecond):
		}
	}
}

// itoa is strconv.Itoa, kept short for the listen address.
func itoa(i int) string { return strconv.Itoa(i) }
