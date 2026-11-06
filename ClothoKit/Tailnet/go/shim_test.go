package main

import (
	"strings"
	"testing"
)

// Config validation only: no node starts, nothing touches the network. The tests that run nodes
// are the Swift ones (ClothoKit/Tailnet/scripts/test.sh), against clothod's testctl.
func TestConfigValidate(t *testing.T) {
	for _, tc := range []struct {
		name string
		cfg  config
		want string // "" = valid
	}{
		{"relative dir", config{dir: "tn", hostname: "h"}, "absolute"},
		{"empty dir", config{hostname: "h"}, "absolute"},
		{"no hostname", config{dir: "/tmp/x"}, "hostname"},
		{"test mode, Tailscale's control", config{dir: "/tmp/x", hostname: "h", testMode: true}, "never joins a real tailnet"},
		{"test mode, remote control", config{dir: "/tmp/x", hostname: "h", testMode: true, controlURL: "https://controlplane.tailscale.com"}, "never joins a real tailnet"},
		{"test mode, loopback", config{dir: "/tmp/x", hostname: "h", testMode: true, controlURL: "http://127.0.0.1:1234"}, ""},
		{"test mode, localhost", config{dir: "/tmp/x", hostname: "h", testMode: true, controlURL: "http://localhost:1234"}, ""},
		{"test mode, ::1", config{dir: "/tmp/x", hostname: "h", testMode: true, controlURL: "http://[::1]:1234"}, ""},
		{"bad URL", config{dir: "/tmp/x", hostname: "h", controlURL: "ftp://x"}, "bad control URL"},
		{"default control", config{dir: "/tmp/x", hostname: "h"}, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := tc.cfg
			err := c.validate()
			switch {
			case tc.want == "" && err != nil:
				t.Fatalf("want valid, got %v", err)
			case tc.want != "" && (err == nil || !strings.Contains(err.Error(), tc.want)):
				t.Fatalf("want an error with %q, got %v", tc.want, err)
			}
			if tc.want == "" && c.controlURL == "" {
				t.Fatalf("control URL left empty")
			}
		})
	}
}
