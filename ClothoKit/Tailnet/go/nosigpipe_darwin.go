package main

import "syscall"

// noSigPipe sets SO_NOSIGPIPE (Darwin's per-socket way to get EPIPE instead of SIGPIPE).
func noSigPipe(fd int) {
	syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_NOSIGPIPE, 1)
}
