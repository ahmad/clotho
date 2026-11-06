// Command clothod-net is clothod's tailnet sidecar: a userspace Tailscale node (tsnet) that lets
// the user's own tailnet devices reach this machine's clothod without SSH. It is a separate
// pure-Go program so that no Go runtime ever runs inside clothod itself (PLAN.md, "Built-in
// Tailscale", decision 1). See README.md.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"runtime/debug"
	"strings"
	"syscall"
	"time"

	"tailscale.com/envknob"
	"tailscale.com/hostinfo"
)

// Set at link time by scripts/build-net.sh.
var (
	version  = "0.0.0-dev"
	devBuild = "" // non-empty: a dev build, whose node is named clothod-<host>-dev
)

// processStart is when this process started, for the time-to-Running figure.
var processStart = time.Now()

const usage = `usage: clothod-net <command> [flags]

clothod's tailnet sidecar: a userspace Tailscale node that lets this user's own tailnet devices
reach this machine's clothod without SSH.

commands:
  login     sign the node in: prints auth_url=<URL> (open it in a browser) and waits until the
            node runs, then prints state=Running, name= and ip=. Works whether or not serve runs.
  status    print the node's state as JSON: asks the running sidecar, else starts the node for
            a moment to find out
  serve --port N
            run the node and accept connections on its tailnet addresses, port N, only. A peer
            must be a device of this node's own Tailscale user (not tagged, not shared in), or
            the connection is closed before anything is read. Then clothod is started if needed
            (as 'clothod bridge' does) and bytes are relayed to its socket.
  dial HOST:PORT
            (tests) join as an ephemeral node, connect to HOST:PORT over the tailnet and copy
            stdin and stdout to it. Exits 0 when stdin ends, 2 when the other side closes.
  version   print this build's version and its tailscale.com version

flags:
  --state-dir DIR     node state goes in DIR/tailnet, 0700 (default: $CLOTHOD_STATE_DIR, else
                      clothod's state dir). One process at a time owns it.
  --control-url URL   coordination server (default: $CLOTHOD_NET_CONTROL_URL, else Tailscale's)
  --hostname NAME     node name (default clothod-<host>; -dev for dev builds and test instances)
  --ephemeral[=SECS|exit]
                      a test instance (also when $CLOTHOD_EPHEMERAL is set): refused unless
                      --control-url and --state-dir are given, so it never joins a real tailnet
                      or uses the machine's node; passed on to the clothod it starts
  --ephemeral-node    register an ephemeral node: control deletes it soon after it goes
                      offline, and a clean exit logs it out (dial always does this)
  -v                  log the node's internals to stderr
  serve: --port N (required), --clothod PATH (default: the clothod next to this binary, else
         $PATH), --runtime-dir DIR (clothod's; default clothod's own)
  login, dial: --timeout DURATION (login 10m, dial 60s)
  status: --timeout DURATION (how long a node started to find out may take; 15s)
`

func main() {
	// Before anything starts: no logs to log.tailscale.com (PLAN decision 8). The release build
	// also compiles logtail out (ts_omit_logtail); this covers builds without the tag.
	envknob.SetNoLogsNoSupport()
	hostinfo.SetApp("clothod")
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	log.SetPrefix("clothod-net: ")

	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(64)
	}
	cmd, args := os.Args[1], os.Args[2:]
	var err error
	switch cmd {
	case "login":
		err = runLogin(args)
	case "status":
		err = runStatus(args)
	case "serve":
		err = runServe(args)
	case "dial":
		err = runDial(args)
	case "version":
		fmt.Printf("clothod-net %s (tailscale.com %s, %s)\n", version, tailscaleVersion(), goVersion())
	case "-h", "--help", "help":
		fmt.Print(usage)
	default:
		fmt.Fprintf(os.Stderr, "clothod-net: unknown command %q\n\n%s", cmd, usage)
		os.Exit(64)
	}
	if err != nil {
		var ec exitCode
		if errors.As(err, &ec) {
			os.Exit(int(ec))
		}
		log.Printf("%v", err)
		os.Exit(1)
	}
}

// exitCode ends the process with that code and no message.
type exitCode int

func (e exitCode) Error() string { return fmt.Sprintf("exit %d", int(e)) }

// optValue is a flag that may be given bare (--ephemeral) or with a value (--ephemeral=exit).
type optValue struct {
	set bool
	v   string
}

func (o *optValue) String() string   { return o.v }
func (o *optValue) IsBoolFlag() bool { return true }
func (o *optValue) Set(s string) error {
	o.set, o.v = true, s
	return nil
}

// flags shared by every command.
type commonFlags struct {
	stateDir   string
	controlURL string
	hostname   string
	ephemeral  optValue
	ephNode    bool
	verbose    bool
}

func newFlagSet(name string, c *commonFlags) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	fs.Usage = func() { fmt.Fprint(os.Stderr, usage) }
	fs.StringVar(&c.stateDir, "state-dir", "", "")
	fs.StringVar(&c.controlURL, "control-url", "", "")
	fs.StringVar(&c.hostname, "hostname", "", "")
	fs.Var(&c.ephemeral, "ephemeral", "")
	fs.BoolVar(&c.ephNode, "ephemeral-node", false, "")
	fs.BoolVar(&c.verbose, "v", false, "")
	return fs
}

// parse parses flags and positional arguments in any order (the flag package alone stops at the
// first positional one).
func parse(fs *flag.FlagSet, args []string, positional int) ([]string, error) {
	var pos []string
	for {
		if err := fs.Parse(args); err != nil {
			return nil, exitCode(64)
		}
		if fs.NArg() == 0 {
			break
		}
		pos = append(pos, fs.Arg(0))
		args = fs.Args()[1:]
	}
	if len(pos) != positional {
		fmt.Fprint(os.Stderr, usage)
		return nil, exitCode(64)
	}
	return pos, nil
}

// signalContext is cancelled by SIGINT or SIGTERM.
func signalContext() (context.Context, context.CancelFunc) {
	return signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
}

func runLogin(args []string) error {
	var c commonFlags
	fs := newFlagSet("login", &c)
	timeout := fs.Duration("timeout", 10*time.Minute, "")
	if _, err := parse(fs, args, 0); err != nil {
		return err
	}
	cfg, err := c.config()
	if err != nil {
		return err
	}
	ctx, cancel := signalContext()
	defer cancel()
	ctx, cancel2 := context.WithTimeout(ctx, *timeout)
	defer cancel2()

	printed := ""
	report := func(st *nodeStatus) bool {
		if st.AuthURL != "" && st.AuthURL != printed {
			printed = st.AuthURL
			fmt.Printf("auth_url=%s\n", st.AuthURL)
		}
		if st.State == "Running" {
			fmt.Printf("state=Running\nname=%s\nip=%s\n", st.DNSName, strings.Join(st.IPs, " "))
			return true
		}
		return false
	}
	// A running sidecar owns the node: follow its status.
	if _, err := askStatus(cfg); err == nil {
		for {
			st, err := askStatus(cfg)
			if err != nil {
				return fmt.Errorf("the running sidecar stopped answering: %w", err)
			}
			if report(st) {
				return nil
			}
			select {
			case <-ctx.Done():
				return fmt.Errorf("not signed in after %v (state %s)", *timeout, st.State)
			case <-time.After(250 * time.Millisecond):
			}
		}
	}
	n, err := openNode(cfg, "login")
	if err != nil {
		return err
	}
	defer n.close()
	if err := n.start(); err != nil {
		return err
	}
	for {
		st := n.status(ctx)
		if report(st) {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("not signed in after %v (state %s)", *timeout, st.State)
		case <-time.After(250 * time.Millisecond):
		}
	}
}

func runStatus(args []string) error {
	var c commonFlags
	fs := newFlagSet("status", &c)
	timeout := fs.Duration("timeout", 15*time.Second, "")
	if _, err := parse(fs, args, 0); err != nil {
		return err
	}
	cfg, err := c.config()
	if err != nil {
		return err
	}
	st, err := askStatus(cfg)
	if err != nil {
		// Nobody runs the node: start it long enough to learn its state.
		n, err := openNode(cfg, "status")
		if err != nil {
			return err
		}
		defer n.close()
		if err := n.start(); err != nil {
			return err
		}
		ctx, cancel := context.WithTimeout(context.Background(), *timeout)
		defer cancel()
		for {
			st = n.status(ctx)
			if st.settled() || ctx.Err() != nil {
				break
			}
			time.Sleep(100 * time.Millisecond)
		}
		st.Running = false
		st.PID = 0
		st.Mode = ""
	}
	out, _ := json.MarshalIndent(st, "", "  ")
	fmt.Println(string(out))
	return nil
}

func runServe(args []string) error {
	var c commonFlags
	fs := newFlagSet("serve", &c)
	port := fs.Int("port", 0, "")
	bin := fs.String("clothod", "", "")
	runtimeDir := fs.String("runtime-dir", "", "")
	if _, err := parse(fs, args, 0); err != nil {
		return err
	}
	if *port <= 0 || *port > 65535 {
		return errors.New("serve needs --port N (1-65535)")
	}
	cfg, err := c.config()
	if err != nil {
		return err
	}
	d, err := newDaemon(*bin, *runtimeDir, cfg.ephemeralArg)
	if err != nil {
		return err
	}
	n, err := openNode(cfg, "serve")
	if err != nil {
		return err
	}
	defer n.close()
	ctx, cancel := signalContext()
	defer cancel()
	return n.serve(ctx, *port, d)
}

func runDial(args []string) error {
	var c commonFlags
	fs := newFlagSet("dial", &c)
	timeout := fs.Duration("timeout", 60*time.Second, "")
	pos, err := parse(fs, args, 1)
	if err != nil {
		return err
	}
	target := pos[0]
	if _, _, err := net.SplitHostPort(target); err != nil {
		return fmt.Errorf("dial needs HOST:PORT: %w", err)
	}
	cfg, err := c.config()
	if err != nil {
		return err
	}
	cfg.ephemeralNode = true // a test tool: never a lasting device
	n, err := openNode(cfg, "dial")
	if err != nil {
		return err
	}
	ctx, cancel := signalContext()
	defer cancel()
	conn, err := n.dial(ctx, target, *timeout)
	if err != nil {
		n.close()
		return err
	}
	// Only protocol bytes on stdout from here on.
	done := make(chan int, 2)
	go func() {
		io.Copy(conn, os.Stdin)
		done <- 0
	}()
	go func() {
		io.Copy(os.Stdout, conn)
		done <- 2
	}()
	code := <-done
	if code == 2 {
		log.Printf("the other side closed the connection")
	}
	conn.Close()
	// Don't wait long on the node's shutdown: the process ends either way.
	closed := make(chan struct{})
	go func() { n.close(); close(closed) }()
	select {
	case <-closed:
	case <-time.After(2 * time.Second):
	}
	if code != 0 {
		return exitCode(code)
	}
	return nil
}

func tailscaleVersion() string {
	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, d := range bi.Deps {
			if d.Path == "tailscale.com" {
				return d.Version
			}
		}
	}
	return "unknown"
}

func goVersion() string {
	if bi, ok := debug.ReadBuildInfo(); ok {
		return bi.GoVersion
	}
	return "unknown"
}
