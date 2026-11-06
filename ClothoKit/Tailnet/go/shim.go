// Package main is Clotho's tailnet shim: a small C API (clotho_tailnet.h) over tailscale.com/tsnet,
// built with -buildmode=c-archive into the ClothoTailnet xcframework (ClothoKit/scripts/
// build-tailnet.sh). See ClothoKit/Tailnet/README.md and PLAN.md, "Built-in Tailscale".
package main

/*
#cgo CFLAGS: -DCTN_GO_BUILD
#include <stdlib.h>
#include "clotho_tailnet.h"

static inline void ctn_call_on_state(ctn_on_state_fn f, void *ctx, const char *json) { f(ctx, json); }
static inline void ctn_call_log(ctn_log_fn f, void *ctx, const char *line) { f(ctx, line); }
static inline void ctn_call_on_closed(ctn_on_closed_fn f, void *ctx) { f(ctx); }
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"tailscale.com/client/local"
	"tailscale.com/envknob"
	"tailscale.com/hostinfo"
	"tailscale.com/ipn"
	"tailscale.com/net/netns"
	"tailscale.com/tsnet"
)

func init() {
	// Before any node starts: no logs to log.tailscale.com (PLAN decision 8). The builds also
	// compile logtail out (-tags ts_omit_logtail); this covers a build without the tag.
	envknob.SetNoLogsNoSupport()
	hostinfo.SetApp("clotho")
}

// main is never run: the archive's caller is the app.
func main() {}

// config is ctn_config in Go terms.
type config struct {
	dir        string
	hostname   string
	controlURL string
	ephemeral  bool
	testMode   bool
}

// validate applies the defaults and the safety rules: an absolute dir, a hostname, and a test
// node only ever joins a control server on this machine.
func (c *config) validate() error {
	if c.dir == "" || !filepath.IsAbs(c.dir) {
		return fmt.Errorf("the node's dir must be an absolute path (got %q)", c.dir)
	}
	c.dir = filepath.Clean(c.dir)
	if c.hostname == "" {
		return errors.New("the node needs a hostname")
	}
	if c.testMode && !isLoopbackURL(c.controlURL) {
		return fmt.Errorf("a test node never joins a real tailnet: its control URL must be on this machine (got %q)", c.controlURL)
	}
	if c.controlURL == "" {
		// Explicit, so $TS_CONTROL_URL in the environment can't move the node elsewhere.
		c.controlURL = ipn.DefaultControlURL
	} else if u, err := url.Parse(c.controlURL); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return fmt.Errorf("bad control URL %q", c.controlURL)
	}
	return nil
}

// isLoopbackURL: an http(s) URL whose host is a loopback address or localhost (as clothod-net).
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

// ensurePrivateDir creates dir 0700 and refuses one that isn't a directory owned by this user.
func ensurePrivateDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	fi, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !fi.IsDir() || !ownedByMe(fi) {
		return fmt.Errorf("%s is not a directory owned by this user; refusing to use it", dir)
	}
	return os.Chmod(dir, 0o700)
}

// node is one running tsnet.Server and the C callbacks it reports to.
type node struct {
	cfg    config
	srv    *tsnet.Server
	lc     *local.Client
	cancel context.CancelFunc // ends the IPN bus watcher
	wg     sync.WaitGroup     // the watcher

	ctx      unsafe.Pointer
	onState  C.ctn_on_state_fn
	logFn    C.ctn_log_fn
	onClosed C.ctn_on_closed_fn

	// closing: ctn_close was called, so on_state and log stop at once. cbMu guards done: the
	// background close takes it for writing, so on_closed runs only after every callback in
	// flight has returned, and none runs after it.
	closing atomic.Bool
	cbMu    sync.RWMutex
	done    bool
	store   *callbackStore
	lastMsg string // the last on_state JSON (watcher goroutine only)
}

var (
	nodesMu sync.Mutex
	nodes   = map[int64]*node{}
	nextID  int64
)

func lookup(h C.ctn_node) (*node, error) {
	nodesMu.Lock()
	defer nodesMu.Unlock()
	n, ok := nodes[int64(h)]
	if !ok {
		return nil, errors.New("the node is stopped")
	}
	return n, nil
}

func setErr(out **C.char, err error) {
	if out != nil && err != nil {
		*out = C.CString(err.Error())
	}
}

func goString(s *C.char) string {
	if s == nil {
		return ""
	}
	return C.GoString(s)
}

// logf sends one line to the log callback, if any and the node isn't closing.
func (n *node) logf(format string, a ...any) {
	if n.logFn == nil || n.closing.Load() {
		return
	}
	n.cbMu.RLock()
	defer n.cbMu.RUnlock()
	if n.done {
		return
	}
	line := C.CString(fmt.Sprintf(format, a...))
	C.ctn_call_log(n.logFn, n.ctx, line)
	C.free(unsafe.Pointer(line))
}

func (n *node) sendState(msg string) {
	if n.onState == nil || n.closing.Load() {
		return
	}
	n.cbMu.RLock()
	defer n.cbMu.RUnlock()
	if n.done {
		return
	}
	s := C.CString(msg)
	C.ctn_call_on_state(n.onState, n.ctx, s)
	C.free(unsafe.Pointer(s))
}

//export ctn_start
func ctn_start(cfg *C.ctn_config, errOut **C.char) C.ctn_node {
	if cfg == nil {
		setErr(errOut, errors.New("no config"))
		return 0
	}
	c := config{
		dir:        goString(cfg.dir),
		hostname:   goString(cfg.hostname),
		controlURL: goString(cfg.control_url),
		ephemeral:  cfg.ephemeral != 0,
		testMode:   cfg.test_mode != 0,
	}
	if err := c.validate(); err != nil {
		setErr(errOut, err)
		return 0
	}
	if (cfg.store_read == nil) != (cfg.store_write == nil) {
		setErr(errOut, errors.New("the state store needs both store_read and store_write"))
		return 0
	}
	if err := ensurePrivateDir(c.dir); err != nil {
		setErr(errOut, err)
		return 0
	}
	if c.testMode {
		// Test nodes stay on this machine: no NAT-PMP/PCP/UPnP requests to the LAN's router, and
		// no binding to the default interface (clothod/net/node.go does the same). Process-wide.
		envknob.Setenv("TS_DISABLE_PORTMAPPER", "true")
		netns.SetEnabled(false)
	}
	// The backend's own files stay in the node's dir: without this it creates tailscaled's default
	// log dir, ~/.local/share/tailscale. Process-wide: the last node started wins.
	os.Setenv("TS_LOGS_DIR", c.dir)

	n := &node{
		cfg:      c,
		ctx:      cfg.ctx,
		onState:  cfg.on_state,
		logFn:    cfg.log,
		onClosed: cfg.on_closed,
	}
	n.srv = &tsnet.Server{
		Dir:        c.dir,
		Hostname:   c.hostname,
		ControlURL: c.controlURL,
		Ephemeral:  c.ephemeral,
		// Both set, so tsnet never writes to stderr (UserLogf defaults to log.Printf).
		UserLogf: func(format string, a ...any) { n.logf("tsnet: "+format, a...) },
		Logf:     func(format string, a ...any) { n.logf(format, a...) },
	}
	if cfg.store_read != nil {
		n.store = &callbackStore{n: n, read: cfg.store_read, write: cfg.store_write}
		n.srv.Store = n.store
	}
	if err := n.srv.Start(); err != nil {
		n.closing.Store(true)
		n.srv.Close()
		setErr(errOut, fmt.Errorf("starting the node: %w", err))
		return 0
	}
	lc, err := n.srv.LocalClient()
	if err != nil {
		n.closing.Store(true)
		n.srv.Close()
		setErr(errOut, err)
		return 0
	}
	n.lc = lc
	ctx, cancel := context.WithCancel(context.Background())
	n.cancel = cancel
	n.wg.Add(1)
	go n.watch(ctx)

	nodesMu.Lock()
	nextID++
	id := nextID
	nodes[id] = n
	nodesMu.Unlock()
	return C.ctn_node(id)
}

// stateMsg is what on_state reports.
type stateMsg struct {
	BackendState string
	AuthURL      string
	Expired      bool
}

// watch follows the IPN bus and reports each change of state, auth URL or expiry to on_state.
func (n *node) watch(ctx context.Context) {
	defer n.wg.Done()
	for ctx.Err() == nil {
		w, err := n.lc.WatchIPNBus(ctx, ipn.NotifyInitialState)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			n.logf("watching the node: %v", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(250 * time.Millisecond):
			}
			continue
		}
		for {
			msg, err := w.Next()
			if err != nil {
				break
			}
			if msg.State == nil && msg.BrowseToURL == nil && msg.SelfChange == nil && msg.LoginFinished == nil {
				continue
			}
			n.report(ctx)
		}
		w.Close()
	}
}

func (n *node) report(ctx context.Context) {
	sctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	st, err := n.lc.StatusWithoutPeers(sctx)
	if err != nil {
		return
	}
	m := stateMsg{BackendState: st.BackendState, AuthURL: st.AuthURL}
	if self := st.Self; self != nil {
		m.Expired = self.Expired || (self.KeyExpiry != nil && !self.KeyExpiry.IsZero() && self.KeyExpiry.Before(time.Now()))
	}
	b, _ := json.Marshal(m)
	if s := string(b); s != n.lastMsg {
		n.lastMsg = s
		n.sendState(s)
	}
}

func timeoutCtx(ms C.int) (context.Context, context.CancelFunc) {
	d := time.Duration(ms) * time.Millisecond
	if d <= 0 {
		d = 10 * time.Second
	}
	return context.WithTimeout(context.Background(), d)
}

func jsonResult(v any, err error, errOut **C.char) *C.char {
	if err != nil {
		setErr(errOut, err)
		return nil
	}
	b, err := json.Marshal(v)
	if err != nil {
		setErr(errOut, err)
		return nil
	}
	return C.CString(string(b))
}

//export ctn_status_json
func ctn_status_json(h C.ctn_node, timeoutMS C.int, errOut **C.char) *C.char {
	n, err := lookup(h)
	if err != nil {
		setErr(errOut, err)
		return nil
	}
	ctx, cancel := timeoutCtx(timeoutMS)
	defer cancel()
	st, err := n.lc.Status(ctx)
	return jsonResult(st, err, errOut)
}

//export ctn_login_interactive
func ctn_login_interactive(h C.ctn_node, timeoutMS C.int, errOut **C.char) *C.char {
	n, err := lookup(h)
	if err != nil {
		setErr(errOut, err)
		return nil
	}
	ctx, cancel := timeoutCtx(timeoutMS)
	defer cancel()
	before, _ := n.lc.StatusWithoutPeers(ctx)
	// After a logout the backend runs a new, empty profile whose control client points at Tailscale's control
	// server: start it again with ours first, so a login never goes to another control server.
	if err := n.restorePrefs(ctx, true); err != nil {
		setErr(errOut, err)
		return nil
	}
	if err := n.lc.StartLoginInteractive(ctx); err != nil {
		setErr(errOut, fmt.Errorf("starting the login: %w", err))
		return nil
	}
	start := time.Now()
	for {
		st, err := n.lc.StatusWithoutPeers(ctx)
		if err != nil {
			setErr(errOut, err)
			return nil
		}
		// A new URL (control may hand out the same one again while a login is pending).
		if st.AuthURL != "" && (before == nil || st.AuthURL != before.AuthURL || before.BackendState != ipn.Running.String()) {
			return C.CString(st.AuthURL)
		}
		// Control signed it in without a browser step (a test control server, or a key).
		if st.BackendState == ipn.Running.String() && time.Since(start) > 2*time.Second {
			return C.CString("")
		}
		select {
		case <-ctx.Done():
			setErr(errOut, fmt.Errorf("no login URL from the control server in time (state %s)", st.BackendState))
			return nil
		case <-time.After(100 * time.Millisecond):
		}
	}
}

//export ctn_logout
func ctn_logout(h C.ctn_node, timeoutMS C.int, errOut **C.char) C.int {
	n, err := lookup(h)
	if err != nil {
		setErr(errOut, err)
		return -1
	}
	ctx, cancel := timeoutCtx(timeoutMS)
	defer cancel()
	if err := n.lc.Logout(ctx); err != nil {
		setErr(errOut, err)
		return -1
	}
	// Logout deletes the profile and starts an empty one with default prefs: Tailscale's control URL and no
	// hostname. Put ours back at once (not running: the node stays signed out until ctn_login_interactive).
	// The empty profile has no node key, so nothing logs in (or reaches any control server) meanwhile.
	if err := n.restorePrefs(ctx, false); err != nil {
		setErr(errOut, err)
		return -1
	}
	return 0
}

// restorePrefs starts the backend again with the node's own prefs: its control URL, its hostname, and
// WantRunning as asked. Needed after a logout: LocalBackend.Logout deletes the profile and starts an empty
// one whose control client points at Tailscale's control server (prefs.ControlURLOrDefault), and editing
// the prefs afterwards doesn't move that client; Start makes a new one. tsnet's own start does the same.
func (n *node) restorePrefs(ctx context.Context, wantRunning bool) error {
	prefs := ipn.NewPrefs()
	prefs.ControlURL = n.cfg.controlURL
	prefs.Hostname = n.cfg.hostname
	prefs.WantRunning = wantRunning
	if err := n.lc.Start(ctx, ipn.Options{UpdatePrefs: prefs}); err != nil {
		return fmt.Errorf("restarting the node with its control server: %w", err)
	}
	p, err := n.lc.GetPrefs(ctx)
	if err != nil {
		return err
	}
	if p.ControlURL != n.cfg.controlURL {
		return fmt.Errorf("the node's control server is %q, not %q", p.ControlURL, n.cfg.controlURL)
	}
	return nil
}

//export ctn_whois
func ctn_whois(h C.ctn_node, addr *C.char, timeoutMS C.int, errOut **C.char) *C.char {
	n, err := lookup(h)
	if err != nil {
		setErr(errOut, err)
		return nil
	}
	ctx, cancel := timeoutCtx(timeoutMS)
	defer cancel()
	who, err := n.lc.WhoIs(ctx, goString(addr))
	return jsonResult(who, err, errOut)
}

//export ctn_dial
func ctn_dial(h C.ctn_node, host *C.char, port C.int, timeoutMS C.int, errOut **C.char) C.int {
	n, err := lookup(h)
	if err != nil {
		setErr(errOut, err)
		return -1
	}
	if port <= 0 || port > 65535 {
		setErr(errOut, fmt.Errorf("bad port %d", int(port)))
		return -1
	}
	ctx, cancel := timeoutCtx(timeoutMS)
	defer cancel()
	fd, err := n.dial(ctx, net.JoinHostPort(goString(host), fmt.Sprint(int(port))))
	if err != nil {
		setErr(errOut, err)
		return -1
	}
	return C.int(fd)
}

//export ctn_close
func ctn_close(h C.ctn_node) {
	nodesMu.Lock()
	n, ok := nodes[int64(h)]
	delete(nodes, int64(h))
	nodesMu.Unlock()
	if !ok {
		return
	}
	n.closing.Store(true)
	n.cancel()
	// Never on the caller's thread: Close can hang for minutes (tailscale/tailscale#21353).
	go func() {
		n.srv.Close()
		n.wg.Wait()
		n.cbMu.Lock()
		n.done = true
		n.cbMu.Unlock()
		if n.onClosed != nil {
			C.ctn_call_on_closed(n.onClosed, n.ctx)
		}
	}()
}

//export ctn_free
func ctn_free(p unsafe.Pointer) {
	C.free(p)
}
