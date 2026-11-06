package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"tailscale.com/client/tailscale/apitype"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
)

// serve runs the node and accepts on its tailnet addresses, port, until ctx ends.
func (n *node) serve(ctx context.Context, port int, d *daemon) error {
	if err := n.start(); err != nil {
		return err
	}
	// tsnet listeners live in its userspace network stack: they accept only on the node's
	// tailnet addresses, never on the machine's own interfaces.
	ln, err := n.srv.Listen("tcp", ":"+itoa(port))
	if err != nil {
		return fmt.Errorf("listening on tailnet port %d: %w", port, err)
	}
	n.listen = ":" + itoa(port)
	go n.watch(ctx)
	go func() {
		<-ctx.Done()
		ln.Close()
	}()
	log.Printf("node %s, state in %s, control %s; accepting on tailnet port %d for clothod %s",
		n.cfg.hostname, n.cfg.stateDir, n.srv.ControlURL, port, d.sock)
	var wg sync.WaitGroup
	defer func() {
		wg.Wait()
		// handle closed connections because ctx ended: give their FINs a moment to reach the
		// peers before the node and its network stack go, or clients would be left with
		// half-open connections until their own timeouts.
		if n.cutShort.Load() {
			time.Sleep(250 * time.Millisecond)
		}
	}()
	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				log.Printf("stopping")
				return nil
			}
			return fmt.Errorf("accept: %w", err)
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			n.handle(ctx, c, d)
		}()
	}
}

// watch logs the node's state changes, the sign-in URL when it needs one, and how long it took
// from process start to Running.
func (n *node) watch(ctx context.Context) {
	w, err := n.lc.WatchIPNBus(ctx, ipn.NotifyInitialState)
	if err != nil {
		log.Printf("watching the node: %v", err)
		return
	}
	defer w.Close()
	last, lastURL := "", ""
	for {
		msg, err := w.Next()
		if err != nil {
			return
		}
		if msg.State == nil && msg.BrowseToURL == nil {
			continue
		}
		st := n.status(ctx)
		if st.State != last {
			last = st.State
			if st.State == "Running" {
				if n.upMS == 0 {
					n.upMS = time.Since(processStart).Milliseconds()
				}
				log.Printf("Running as %s (%s), %d ms after start", st.DNSName, strings.Join(st.IPs, ", "), n.upMS)
			} else {
				log.Printf("state %s", st.State)
			}
		}
		if st.AuthURL != "" && st.AuthURL != lastURL {
			lastURL = st.AuthURL
			log.Printf("needs sign-in: open %s (or run `clothod-net login`)", st.AuthURL)
		}
	}
}

// handle checks the peer before reading a byte from it, then relays it to clothod. A refused
// peer is closed without a word: it learns nothing about this machine.
func (n *node) handle(ctx context.Context, c net.Conn, d *daemon) {
	defer c.Close()
	remote := c.RemoteAddr().String()
	wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	who, err := n.lc.WhoIs(wctx, remote)
	var self *ipnstate.Status
	if err == nil {
		self, err = n.lc.StatusWithoutPeers(wctx)
	}
	cancel()
	if err != nil {
		log.Printf("refused %s: can't identify it: %v", remote, err)
		return
	}
	if ok, why := allowPeer(self.Self, who); !ok {
		log.Printf("refused %s: %s", remote, why)
		return
	}
	sock, err := d.connect(ctx)
	if err != nil {
		log.Printf("accepted %s (%s), but clothod isn't reachable: %v", remote, peerName(who), err)
		return
	}
	log.Printf("accepted %s (%s)", remote, peerName(who))
	// Shutting down ends the connections too (serve waits for them).
	stop := context.AfterFunc(ctx, func() {
		n.cutShort.Store(true)
		log.Printf("closing %s: stopping", remote)
		c.Close()
		sock.Close()
	})
	defer stop()
	relay(c, sock)
}

func peerName(who *apitype.WhoIsResponse) string {
	name := strings.TrimSuffix(who.Node.Name, ".")
	if who.UserProfile != nil && who.UserProfile.LoginName != "" {
		name += ", " + who.UserProfile.LoginName
	}
	return name
}

// allowPeer is the peer check (PLAN.md decision 10): a peer gets in only if it is a device of
// this node's own Tailscale user. Identity is the user ID control assigns, never a login name.
// Tagged peers (no user identity) and peers shared in from another tailnet are refused, and so
// is everyone while this node itself has no user (tagged, or not signed in).
func allowPeer(self *ipnstate.PeerStatus, who *apitype.WhoIsResponse) (bool, string) {
	switch {
	case self == nil || self.UserID == 0:
		return false, "this node has no user yet"
	case self.Tags != nil && self.Tags.Len() > 0:
		return false, "this node is tagged, so it has no user to match"
	case who == nil || who.Node == nil || who.UserProfile == nil:
		return false, "unknown peer"
	case who.Node.IsTagged():
		return false, fmt.Sprintf("tagged peer %v", who.Node.Tags)
	case who.Node.Sharer != 0:
		return false, fmt.Sprintf("peer shared in by user %d", who.Node.Sharer)
	case who.UserProfile.ID != self.UserID || who.Node.User != self.UserID:
		return false, fmt.Sprintf("another user's device (user %d, this node's is %d)", who.UserProfile.ID, self.UserID)
	}
	return true, ""
}

// relay copies both ways until either side ends, then closes both (as `clothod bridge` does).
func relay(a, b net.Conn) {
	done := make(chan struct{}, 2)
	go func() {
		io.Copy(b, a)
		done <- struct{}{}
	}()
	go func() {
		io.Copy(a, b)
		done <- struct{}{}
	}()
	<-done
	a.Close()
	b.Close()
	<-done
}

// daemon is the local clothod: its socket, and how to start it.
type daemon struct {
	bin        string
	runtimeDir string
	ephemeral  string
	sock       string
	mu         sync.Mutex // one `clothod start` at a time
}

// newDaemon finds clothod (--clothod, else next to this binary, else $PATH) and asks it for its
// socket path (`clothod status --print-socket`: clients never compute it).
func newDaemon(bin, runtimeDir, ephemeral string) (*daemon, error) {
	if bin == "" {
		if exe, err := os.Executable(); err == nil {
			if p := filepath.Join(filepath.Dir(exe), "clothod"); isExecutable(p) {
				bin = p
			}
		}
	}
	if bin == "" {
		p, err := exec.LookPath("clothod")
		if err != nil {
			return nil, errors.New("no clothod next to clothod-net or on PATH; pass --clothod PATH")
		}
		bin = p
	}
	d := &daemon{bin: bin, runtimeDir: runtimeDir, ephemeral: ephemeral}
	out, err := exec.Command(bin, d.args("status", "--print-socket")...).Output()
	if err != nil {
		return nil, fmt.Errorf("%s status --print-socket: %w", bin, err)
	}
	d.sock = strings.TrimSpace(string(out))
	if d.sock == "" {
		return nil, fmt.Errorf("%s status --print-socket printed nothing", bin)
	}
	return d, nil
}

func isExecutable(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular() && fi.Mode()&0o111 != 0
}

func (d *daemon) args(cmd ...string) []string {
	a := append([]string{}, cmd...)
	if d.runtimeDir != "" {
		a = append(a, "--runtime-dir", d.runtimeDir)
	}
	if d.ephemeral != "" {
		a = append(a, "--ephemeral="+d.ephemeral)
	}
	return a
}

// connect connects to clothod's socket, starting clothod first if it doesn't answer, the way
// `clothod bridge` does (`clothod start` waits until it accepts).
func (d *daemon) connect(ctx context.Context) (net.Conn, error) {
	var dl net.Dialer
	if c, err := dl.DialContext(ctx, "unix", d.sock); err == nil {
		return c, nil
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if c, err := dl.DialContext(ctx, "unix", d.sock); err == nil {
		return c, nil // another connection started it meanwhile
	}
	sctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(sctx, d.bin, d.args("start", "--quiet")...)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("clothod start: %v: %s", err, strings.TrimSpace(out.String()))
	}
	log.Printf("started clothod")
	return dl.DialContext(ctx, "unix", d.sock)
}
