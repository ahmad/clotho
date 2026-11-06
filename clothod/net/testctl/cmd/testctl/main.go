// Command testctl runs the offline test control plane (package testctl) on its own, for tests in
// other languages (the Mac and iOS apps' tests). It prints one line, `control_url=<URL>`, on
// stdout once it serves, then logs to stderr until SIGINT or SIGTERM, or until stdin closes with
// --exit-with-stdin (so a test runner that dies never leaves it behind).
//
//	testctl [--addr 127.0.0.1:0] [--require-auth] [--exit-with-stdin] [-v]
//
// See package testctl for the hostname rules that pick each node's user and tags, and README.md.
package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"testing"

	"github.com/ahmad/clotho/clothod/net/testctl"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:0", "control listen address (loopback only); DERP and STUN use the same IP")
	requireAuth := flag.Bool("require-auth", false, "new nodes log in interactively: GET their AuthURL to complete it")
	withStdin := flag.Bool("exit-with-stdin", false, "exit when stdin reaches EOF")
	verbose := flag.Bool("v", false, "log the control server's requests")
	flag.Parse()
	log.SetPrefix("testctl: ")

	tb := &procTB{}
	opts := testctl.Options{Addr: *addr, RequireAuth: *requireAuth}
	if *verbose {
		opts.Logf = log.Printf
	}
	s, err := testctl.Start(tb, opts)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("control_url=%s\n", s.URL)
	log.Printf("serving %s (require-auth=%v)", s.URL, *requireAuth)

	done := make(chan string, 2)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() { done <- (<-sig).String() }()
	if *withStdin {
		go func() {
			io.Copy(io.Discard, os.Stdin)
			done <- "stdin closed"
		}()
	}
	why := <-done
	log.Printf("stopping (%s)", why)
	tb.runCleanups()
}

// procTB is the testing.TB that integration.RunDERPAndSTUN needs, for a process that isn't a
// test: failures end the process, and cleanups run at exit.
type procTB struct {
	testing.TB // nil: any method not overridden here panics
	mu         sync.Mutex
	cleanups   []func()
}

func (t *procTB) Cleanup(f func()) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.cleanups = append(t.cleanups, f)
}

func (t *procTB) runCleanups() {
	t.mu.Lock()
	fs := t.cleanups
	t.cleanups = nil
	t.mu.Unlock()
	for i := len(fs) - 1; i >= 0; i-- {
		fs[i]()
	}
}

func (t *procTB) Helper()                           {}
func (t *procTB) Name() string                      { return "testctl" }
func (t *procTB) Log(args ...any)                   { log.Print(args...) }
func (t *procTB) Logf(format string, args ...any)   { log.Printf(format, args...) }
func (t *procTB) Error(args ...any)                 { log.Fatal(args...) }
func (t *procTB) Errorf(format string, args ...any) { log.Fatalf(format, args...) }
func (t *procTB) Fatal(args ...any)                 { log.Fatal(args...) }
func (t *procTB) Fatalf(format string, args ...any) { log.Fatalf(format, args...) }
func (t *procTB) Fail()                             { log.Fatal("failed") }
func (t *procTB) FailNow()                          { log.Fatal("failed") }
func (t *procTB) Failed() bool                      { return false }
