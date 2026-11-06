// clotho_tailnet.h: the C API of Clotho's tailnet shim (ClothoKit/Tailnet/go), a small Go layer over
// tailscale.com/tsnet built as a static library (PLAN.md, "Built-in Tailscale", decision 2).
//
// Conventions:
// - Every string passed in is UTF-8 and NUL-terminated; the shim copies what it keeps.
// - Every string or buffer returned is malloc'd: free it with ctn_free.
// - On failure a call returns 0, -1 or NULL and, when `err` isn't NULL, sets *err to a malloc'd
//   message (free it with ctn_free). On success *err is left alone.
// - Calls block the calling thread (up to their timeout), except ctn_start and ctn_close, which
//   return at once. Call them off the main thread.
// - Process-wide: log upload to Tailscale is off (decision 8), the Hostinfo app is "clotho", and
//   TS_LOGS_DIR is set to the dir of the node started last, so tailscaled's default log dir
//   (~/.local/share/tailscale) is never created. Test mode turns the port mapper and netns
//   binding off for the whole process.
#ifndef CLOTHO_TAILNET_H
#define CLOTHO_TAILNET_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// A running node: > 0. 0 means none.
typedef int64_t ctn_node;

// The state store (optional): node state as key/value pairs instead of <dir>/tailscaled.state, so
// iOS can keep it in the Keychain. Called on the shim's own threads (never the caller's), at any
// time while the node runs and while it closes; must be thread-safe and quick.
// - read: 0 = found (*out is a malloc'd copy of the value, which the shim frees, and *len its
//   length), 1 = no such key, -1 = error.
// - write: replaces the key's value; len 0 with data NULL deletes it. 0 = ok, else error.
typedef int (*ctn_store_read_fn)(void *ctx, const char *key, uint8_t **out, size_t *len);
typedef int (*ctn_store_write_fn)(void *ctx, const char *key, const uint8_t *data, size_t len);
// State changes, as JSON: {"BackendState": "NeedsLogin", "AuthURL": "https://...", "Expired": false}.
// BackendState is NoState, Starting, NeedsLogin, NeedsMachineAuth, Stopped or Running; Expired is
// true when the node's key has expired (a NeedsLogin that wants "sign in again"). Sent once at
// start and then on each change, on a shim thread.
typedef void (*ctn_on_state_fn)(void *ctx, const char *json);
// The node's own log lines (verbose). Without it nothing is logged, and nothing goes to stderr.
typedef void (*ctn_log_fn)(void *ctx, const char *line);
// Called once, on a shim thread, when the node has fully closed after ctn_close (its background
// shutdown finished). From then on no callback runs again, so ctx can be released here. Never
// called if the shutdown hangs (tailscale/tailscale#21353): then ctx must stay alive.
typedef void (*ctn_on_closed_fn)(void *ctx);

typedef struct {
    const char *dir;          // required, absolute: the node's dir (0700; state file unless a store is set)
    const char *hostname;     // required: clotho-<device>, -dev for dev builds (PLAN decision 7)
    const char *control_url;  // NULL or "" = Tailscale's (https://controlplane.tailscale.com)
    int ephemeral;            // register an ephemeral node (dev and test nodes only, decision 5)
    int test_mode;            // tests: port mapper and netns off; refused unless control_url is loopback
    void *ctx;                // passed to every callback below
    ctn_store_read_fn store_read;   // both or neither
    ctn_store_write_fn store_write;
    ctn_on_state_fn on_state;       // optional
    ctn_log_fn log;                 // optional
    ctn_on_closed_fn on_closed;     // optional
} ctn_config;

#ifndef CTN_GO_BUILD
// Starts the node and returns at once, without waiting for it to run (watch on_state or
// ctn_status_json). > 0: the node. 0: refused or failed (*err says why), and no callback ever runs.
ctn_node ctn_start(const ctn_config *cfg, char **err);
// The node's ipnstate.Status as JSON, with peers: BackendState, AuthURL, Self (ID, UserID,
// HostName, DNSName, TailscaleIPs, KeyExpiry, Expired, ...), Peer (by node key), User.
char *ctn_status_json(ctn_node node, int timeout_ms, char **err);
// Starts an interactive login and waits for its URL (the user opens it in a browser). Returns ""
// when the node is running and control signed it in without one.
char *ctn_login_interactive(ctn_node node, int timeout_ms, char **err);
// Signs the node out (its key is expired on the control server): 0 = ok, -1 = error.
int ctn_logout(ctn_node node, int timeout_ms, char **err);
// Connects to host:port over the tailnet (host: a tailnet IP or a MagicDNS name), retrying while
// the node starts or the peer isn't known yet, until timeout_ms. Returns a connected stream socket
// (one end of an AF_UNIX socketpair; close-on-exec, SO_NOSIGPIPE) that the caller owns and closes;
// the shim relays it to the tailnet connection. -1 = error.
int ctn_dial(ctn_node node, const char *host, int port, int timeout_ms, char **err);
// Who is behind a tailnet address ("100.x.y.z" or "100.x.y.z:port"): apitype.WhoIsResponse as
// JSON (Node: ID, Name, Tags, Sharer, ...; UserProfile: ID, LoginName, DisplayName).
char *ctn_whois(ctn_node node, const char *addr, int timeout_ms, char **err);
// Stops the node and returns at once: the shutdown runs in the background, because tsnet's Close
// can hang for minutes (tailscale/tailscale#21353). Calls on the node fail from now on; on_state
// and log stop at once; the store may still be called until on_closed.
void ctn_close(ctn_node node);
// Frees what the shim returned.
void ctn_free(void *p);
#endif

#ifdef __cplusplus
}
#endif

#endif
