package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"syscall"
	"time"
)

// dial connects to target over the tailnet and returns one end of a socketpair that the shim
// relays to that connection. It retries while the node starts or the peer isn't in the netmap yet,
// until ctx ends; a refused connection fails at once.
func (n *node) dial(ctx context.Context, target string) (int, error) {
	var conn net.Conn
	var last error
	for {
		dctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		c, err := n.srv.Dial(dctx, "tcp", target)
		cancel()
		if err == nil {
			conn = c
			break
		}
		last = err
		if strings.Contains(err.Error(), "connection refused") {
			return -1, fmt.Errorf("dialing %s: %w", target, err)
		}
		select {
		case <-ctx.Done():
			return -1, fmt.Errorf("dialing %s: %w", target, last)
		case <-time.After(200 * time.Millisecond):
		}
	}
	theirs, err := relay(conn)
	if err != nil {
		conn.Close()
		return -1, err
	}
	return theirs, nil
}

// relay makes a socketpair, copies bytes between one end and conn in both directions (passing on
// half-closes), and returns the other end, which Go never touches again.
func relay(conn net.Conn) (int, error) {
	// Under ForkLock, so no fork in this process inherits either end before it is close-on-exec.
	syscall.ForkLock.RLock()
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err == nil {
		syscall.CloseOnExec(fds[0])
		syscall.CloseOnExec(fds[1])
	}
	syscall.ForkLock.RUnlock()
	if err != nil {
		return -1, fmt.Errorf("socketpair: %w", err)
	}
	ours, theirs := fds[0], fds[1]
	// A write to a closed peer fails with EPIPE instead of raising SIGPIPE, on both ends.
	noSigPipe(ours)
	noSigPipe(theirs)
	f := os.NewFile(uintptr(ours), "tailnet-relay")
	local, err := net.FileConn(f) // dups the fd
	f.Close()
	if err != nil {
		syscall.Close(theirs)
		return -1, fmt.Errorf("relay: %w", err)
	}
	uc := local.(*net.UnixConn)
	go func() {
		done := make(chan error, 2)
		go func() { // app -> tailnet
			_, err := io.Copy(conn, uc)
			if cw, ok := conn.(interface{ CloseWrite() error }); ok && err == nil {
				cw.CloseWrite()
			} else {
				conn.Close()
			}
			done <- err
		}()
		go func() { // tailnet -> app
			_, err := io.Copy(uc, conn)
			if err == nil {
				uc.CloseWrite()
			} else {
				uc.Close()
			}
			done <- err
		}()
		first := <-done
		if first != nil && !errors.Is(first, net.ErrClosed) {
			// One side failed (the app closed its end, the peer reset): end both.
			conn.Close()
			uc.Close()
		}
		<-done
		conn.Close()
		uc.Close()
	}()
	return theirs, nil
}

// ownedByMe: the file belongs to this process's user.
func ownedByMe(fi os.FileInfo) bool {
	st, ok := fi.Sys().(*syscall.Stat_t)
	return ok && int(st.Uid) == os.Getuid()
}
