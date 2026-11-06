//go:build !darwin

package main

// noSigPipe: Darwin only (the shim ships for Apple platforms; other builds are for go test).
func noSigPipe(fd int) {}
