package main

import (
	"strings"
	"testing"

	"tailscale.com/client/tailscale/apitype"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
	"tailscale.com/types/views"
)

func TestAllowPeer(t *testing.T) {
	const me, other = tailcfg.UserID(7), tailcfg.UserID(8)
	self := &ipnstate.PeerStatus{UserID: me}
	tags := views.SliceOf([]string{"tag:server"})
	taggedSelf := &ipnstate.PeerStatus{UserID: me, Tags: &tags}
	peer := func(user, profile tailcfg.UserID, mod func(*tailcfg.Node)) *apitype.WhoIsResponse {
		n := &tailcfg.Node{User: user}
		if mod != nil {
			mod(n)
		}
		return &apitype.WhoIsResponse{Node: n, UserProfile: &tailcfg.UserProfile{ID: profile, LoginName: "same@example.com"}}
	}
	for _, tc := range []struct {
		name string
		self *ipnstate.PeerStatus
		who  *apitype.WhoIsResponse
		want string // "" = allowed, else part of the reason
	}{
		{"same user", self, peer(me, me, nil), ""},
		{"other user, same login name", self, peer(other, other, nil), "another user"},
		{"node user differs from profile", self, peer(other, me, nil), "another user"},
		{"tagged peer owned by my user ID", self, peer(me, me, func(n *tailcfg.Node) { n.Tags = []string{"tag:x"} }), "tagged peer"},
		{"shared in", self, peer(me, me, func(n *tailcfg.Node) { n.Sharer = other }), "shared in"},
		{"no profile", self, &apitype.WhoIsResponse{Node: &tailcfg.Node{User: me}}, "unknown peer"},
		{"nil whois", self, nil, "unknown peer"},
		{"self not signed in", &ipnstate.PeerStatus{}, peer(me, me, nil), "no user yet"},
		{"self missing", nil, peer(me, me, nil), "no user yet"},
		{"self tagged", taggedSelf, peer(me, me, nil), "this node is tagged"},
	} {
		ok, why := allowPeer(tc.self, tc.who)
		if tc.want == "" {
			if !ok {
				t.Errorf("%s: refused (%s), want allowed", tc.name, why)
			}
			continue
		}
		if ok || !strings.Contains(why, tc.want) {
			t.Errorf("%s: allowed=%v %q, want refused with %q", tc.name, ok, why, tc.want)
		}
	}
}

func TestDefaultHostname(t *testing.T) {
	h := defaultHostname(false)
	if !strings.HasPrefix(h, "clothod-") || strings.HasSuffix(h, "-dev") || strings.ContainsAny(h, ". _") {
		t.Errorf("defaultHostname(false) = %q", h)
	}
	if d := defaultHostname(true); d != h+"-dev" {
		t.Errorf("defaultHostname(true) = %q, want %q", d, h+"-dev")
	}
}
