// Command tailnet-testpeer is a test-only tailnet node for ClothoKit/Tailnet's tests: it joins a
// test control server on this machine (clothod's testctl), listens on its tailnet address and
// forwards each connection to a local address, such as this Mac's own sshd. It never joins a real
// tailnet: the control URL must be loopback.
//
//	tailnet-testpeer --control-url URL --dir DIR [--hostname NAME] [--forward PORT=HOST:PORT]...
//
// It prints `ip=<tailnet IPv4>` on stdout once it runs, then logs to stderr, and exits when stdin
// closes (so a test runner that dies never leaves it behind) or on SIGINT/SIGTERM.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"tailscale.com/envknob"
	"tailscale.com/hostinfo"
	"tailscale.com/net/netns"
	"tailscale.com/tsnet"
)

type forwards []string

func (f *forwards) String() string     { return strings.Join(*f, ",") }
func (f *forwards) Set(s string) error { *f = append(*f, s); return nil }

func main() {
	envknob.SetNoLogsNoSupport()
	hostinfo.SetApp("clotho-testpeer")
	controlURL := flag.String("control-url", "", "test control server (loopback only)")
	dir := flag.String("dir", "", "the node's state dir")
	hostname := flag.String("hostname", "cmac-testpeer", "node name (testctl: other-* is a second user)")
	verbose := flag.Bool("v", false, "log the node's internals")
	var fwd forwards
	flag.Var(&fwd, "forward", "PORT=HOST:PORT: forward tailnet port PORT to HOST:PORT (repeatable)")
	flag.Parse()
	log.SetPrefix("tailnet-testpeer: ")

	u, err := url.Parse(*controlURL)
	if err != nil || (u.Hostname() != "localhost" && !isLoopback(u.Hostname())) {
		log.Fatalf("--control-url must be a test control server on this machine (got %q)", *controlURL)
	}
	if *dir == "" {
		log.Fatal("--dir is required")
	}
	envknob.Setenv("TS_DISABLE_PORTMAPPER", "true")
	netns.SetEnabled(false)
	os.MkdirAll(*dir, 0o700)
	os.Setenv("TS_LOGS_DIR", *dir)

	srv := &tsnet.Server{
		Dir:        *dir,
		Hostname:   *hostname,
		ControlURL: *controlURL,
		Ephemeral:  true,
		UserLogf:   func(string, ...any) {},
	}
	if *verbose {
		srv.Logf = log.Printf
	}
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	go func() {
		io.Copy(io.Discard, os.Stdin)
		cancel()
	}()
	upCtx, upCancel := context.WithTimeout(ctx, 60*time.Second)
	st, err := srv.Up(upCtx)
	upCancel()
	if err != nil {
		log.Fatalf("joining: %v", err)
	}
	for _, f := range fwd {
		port, target, ok := strings.Cut(f, "=")
		if !ok {
			log.Fatalf("bad --forward %q (want PORT=HOST:PORT)", f)
		}
		ln, err := srv.Listen("tcp", ":"+port)
		if err != nil {
			log.Fatalf("listen :%s: %v", port, err)
		}
		go serve(ln, target)
	}
	ip := ""
	for _, a := range st.TailscaleIPs {
		if a.Is4() {
			ip = a.String()
		}
	}
	fmt.Printf("ip=%s\n", ip)
	<-ctx.Done()
	done := make(chan struct{})
	go func() { srv.Close(); close(done) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
	}
}

func serve(ln net.Listener, target string) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go func() {
			defer c.Close()
			t, err := net.DialTimeout("tcp", target, 5*time.Second)
			if err != nil {
				log.Printf("forward to %s: %v", target, err)
				return
			}
			defer t.Close()
			done := make(chan struct{}, 2)
			go func() { io.Copy(t, c); done <- struct{}{} }()
			go func() { io.Copy(c, t); done <- struct{}{} }()
			<-done
		}()
	}
}

func isLoopback(h string) bool {
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}
