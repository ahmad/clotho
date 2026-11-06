// Package testctl runs an offline Tailscale control plane for tests: Tailscale's own
// tstest/integration/testcontrol plus a DERP and a STUN server, all on 127.0.0.1. Nodes that use
// its URL as their control URL form a private test tailnet; nothing here talks to Tailscale.
//
// Identities come from the hostname a node registers with, so nodes in other processes (the
// sidecar, the apps' shims) can pick theirs without an API:
//
//	other-*    the second user (user B)
//	tagged-*   a tagged node (tag:clotho-test), still owned by user A's ID, so a peer check that
//	           only compared users would let it in
//	shared-*   a node shared in from another tailnet: owned by user A's ID, Sharer user B
//	anything   user A, the tailnet's owner
//
// A node that advertises tags (tsnet's AdvertiseTags) gets those tags.
//
// With RequireAuth, a new node's AuthURL is <URL>/auth/<id>, and a GET of that URL completes the
// login, the way a browser visit does on the real service (Server.CompleteAuth does it in
// process).
package testctl

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"tailscale.com/derp/derpserver"
	"tailscale.com/net/stun/stuntest"
	"tailscale.com/tailcfg"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

// Hostname prefixes that choose a node's identity (see the package doc).
const (
	OtherUserPrefix = "other-"
	TaggedPrefix    = "tagged-"
	SharedPrefix    = "shared-"
	// TestTag is the tag a tagged-* node gets.
	TestTag = "tag:clotho-test"
	// MagicDNSDomain is the test tailnet's DNS suffix (nodes are <hostname>.<MagicDNSDomain>).
	MagicDNSDomain = "clotho-test.ts.net"
)

// Options configure a Server. The zero value is ready to use.
type Options struct {
	// Addr is the control server's listen address, 127.0.0.1:0 when empty. DERP and STUN listen
	// on the same IP. Only loopback addresses are allowed.
	Addr string
	// RequireAuth makes each new node log in interactively (see the package doc).
	RequireAuth bool
	// Logf receives the control server's logs; nil discards them.
	Logf logger.Logf
}

// Server is a running test control plane.
type Server struct {
	// URL is the control URL to give nodes (http://127.0.0.1:<port>, no trailing slash).
	URL     string
	Control *testcontrol.Server

	ln   net.Listener
	http *http.Server

	mu    sync.Mutex
	users map[string]tailcfg.UserID // "a", "b": the user IDs testcontrol gave the first node of each
	fixed map[key.NodePublic]bool   // nodes whose identity is set
}

// Start starts a test control plane. Everything it starts stops in tb's cleanup (or at Close).
func Start(tb testing.TB, opts Options) (*Server, error) {
	addr := opts.Addr
	if addr == "" {
		addr = "127.0.0.1:0"
	}
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, fmt.Errorf("testctl: bad address %q: %w", addr, err)
	}
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		return nil, fmt.Errorf("testctl: %q is not a loopback address; the test tailnet stays on this machine", addr)
	}
	logf := opts.Logf
	if logf == nil {
		logf = logger.Discard
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	s := &Server{
		URL:   "http://" + ln.Addr().String(),
		ln:    ln,
		users: map[string]tailcfg.UserID{},
		fixed: map[key.NodePublic]bool{},
	}
	derpMap, err := runDERPAndSTUN(tb, host)
	if err != nil {
		ln.Close()
		return nil, err
	}
	s.Control = &testcontrol.Server{
		DERPMap:         derpMap,
		DNSConfig:       &tailcfg.DNSConfig{Proxied: true},
		MagicDNSDomain:  MagicDNSDomain,
		RequireAuth:     opts.RequireAuth,
		AllOnline:       true,
		ExplicitBaseURL: s.URL,
		Logf:            logf,
	}
	s.Control.HoldMapRequest = func(req *tailcfg.MapRequest) func() {
		s.fixIdentity(req.NodeKey)
		return nil
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /auth/", func(w http.ResponseWriter, r *http.Request) {
		if !s.Control.CompleteAuth(r.URL.Path) {
			http.Error(w, "no such login", http.StatusNotFound)
			return
		}
		fmt.Fprintln(w, "Logged in to the test tailnet. You can close this page.")
	})
	mux.HandleFunc("GET /testctl/nodes", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(s.Nodes())
	})
	mux.Handle("/", s.Control)
	s.http = &http.Server{Handler: mux, ErrorLog: logger.StdLogger(logf)}
	go s.http.Serve(ln)
	tb.Cleanup(s.Close)
	return s, nil
}

// Close stops the control server (DERP and STUN stop with tb's cleanup).
func (s *Server) Close() {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := s.http.Shutdown(ctx); err != nil {
		s.http.Close()
	}
}

// CompleteAuth completes the interactive login behind authURL, as visiting it would.
func (s *Server) CompleteAuth(authURL string) bool {
	return s.Control.CompleteAuth(authURL)
}

// fixIdentity gives a node its user, tags and sharer from its hostname, once, before control
// answers its first map request (so its first netmap already has them; peers get an update).
func (s *Server) fixIdentity(nk key.NodePublic) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.fixed[nk] {
		return
	}
	n := s.Control.Node(nk)
	if n == nil {
		return
	}
	s.fixed[nk] = true
	name := ""
	var reqTags []string
	if n.Hostinfo.Valid() {
		name = strings.ToLower(n.Hostinfo.Hostname())
		reqTags = n.Hostinfo.RequestTags().AsSlice()
	}
	who := "a"
	if strings.HasPrefix(name, OtherUserPrefix) {
		who = "b"
	}
	changed := false
	if id, ok := s.users[who]; !ok {
		s.users[who] = n.User // the first node of each user keeps the ID (and profile) it got
	} else if n.User != id {
		n.User = id
		changed = true
	}
	tags := reqTags
	if len(tags) == 0 && strings.HasPrefix(name, TaggedPrefix) {
		tags = []string{TestTag}
	}
	if len(tags) > 0 && !slices.Equal(n.Tags, tags) {
		n.Tags = tags
		changed = true
	}
	if strings.HasPrefix(name, SharedPrefix) {
		b, ok := s.users["b"]
		if !ok {
			b = 9999 // no user B yet: any other ID will do
		}
		n.Sharer = b
		changed = true
	}
	if changed {
		s.Control.UpdateNode(n)
	}
}

// NodeInfo is one node as GET /testctl/nodes lists it.
type NodeInfo struct {
	Hostname string         `json:"hostname"`
	IPs      []string       `json:"ips"`
	User     tailcfg.UserID `json:"user"`
	Tags     []string       `json:"tags,omitempty"`
	Sharer   tailcfg.UserID `json:"sharer,omitempty"`
}

// Nodes lists the nodes registered so far.
func (s *Server) Nodes() []NodeInfo {
	var out []NodeInfo
	for _, n := range s.Control.AllNodes() {
		ni := NodeInfo{User: n.User, Tags: n.Tags, Sharer: n.Sharer}
		if n.Hostinfo.Valid() {
			ni.Hostname = n.Hostinfo.Hostname()
		}
		for _, a := range n.Addresses {
			ni.IPs = append(ni.IPs, a.Addr().String())
		}
		out = append(out, ni)
	}
	return out
}

// runDERPAndSTUN starts a DERP server (TLS, self-signed: the map marks it InsecureForTests) and
// a STUN server, both on ip only. It is integration.RunDERPAndSTUN, except that its STUN server
// listens on all interfaces.
func runDERPAndSTUN(tb testing.TB, ip string) (*tailcfg.DERPMap, error) {
	d := derpserver.New(key.NewNode(), logger.Discard)
	ln, err := net.Listen("tcp", net.JoinHostPort(ip, "0"))
	if err != nil {
		return nil, err
	}
	httpsrv := httptest.NewUnstartedServer(derpserver.Handler(d))
	httpsrv.Listener.Close()
	httpsrv.Listener = ln
	httpsrv.Config.ErrorLog = logger.StdLogger(logger.Discard)
	httpsrv.Config.TLSNextProto = make(map[string]func(*http.Server, *tls.Conn, http.Handler))
	httpsrv.StartTLS()

	stunAddr, stunCleanup := stuntest.ServeWithPacketListener(tb, loopbackListener(ip))
	tb.Cleanup(func() {
		httpsrv.CloseClientConnections()
		httpsrv.Close()
		d.Close()
		stunCleanup()
	})
	return &tailcfg.DERPMap{
		Regions: map[tailcfg.DERPRegionID]*tailcfg.DERPRegion{
			1: {
				RegionID:   1,
				RegionCode: "test",
				Nodes: []*tailcfg.DERPNode{{
					Name:             "t1",
					RegionID:         1,
					HostName:         ip,
					IPv4:             ip,
					IPv6:             "none",
					STUNPort:         stunAddr.Port,
					DERPPort:         ln.Addr().(*net.TCPAddr).Port,
					InsecureForTests: true,
					STUNTestIP:       ip,
				}},
			},
		},
	}, nil
}

// loopbackListener listens on its IP whatever address it's asked for (stuntest asks for ":0").
type loopbackListener string

func (ip loopbackListener) ListenPacket(ctx context.Context, network, _ string) (net.PacketConn, error) {
	var lc net.ListenConfig
	return lc.ListenPacket(ctx, network, net.JoinHostPort(string(ip), "0"))
}
