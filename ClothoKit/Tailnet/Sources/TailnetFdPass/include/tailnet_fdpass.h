// Unix-socket helpers for the tailnet ssh path: the app's TailnetProxyServer and clotho-tailnet-proxy
// (ssh's ProxyCommand with ProxyUseFdpass=yes). Plain POSIX, no Foundation. Every call retries on EINTR,
// and every wait has a deadline. Errors return -1 with errno set, unless said otherwise.
#ifndef TAILNET_FDPASS_H
#define TAILNET_FDPASS_H

#include <stddef.h>
#include <sys/types.h>

// Sends fd over the Unix stream socket sock: one data byte with the fd as SCM_RIGHTS (what ssh's
// ProxyUseFdpass expects on the proxy command's stdout). 0 = sent.
int tfp_send_fd(int sock, int fd);

// Waits up to timeout_ms for one message on sock. >= 0: a received fd (close-on-exec). -2: a message
// without an fd: its text is copied into buf (NUL-terminated, at most buflen - 1 bytes). -1: error,
// timeout (errno ETIMEDOUT) or the other side closed (errno ECONNRESET).
int tfp_recv_fd(int sock, int timeout_ms, char *buf, size_t buflen);

// Connects to the Unix socket at path (SO_NOSIGPIPE, close-on-exec). The fd, or -1 (ENAMETOOLONG when the
// path doesn't fit in sun_path).
int tfp_connect(const char *path);

// Binds and listens on path: removes a stale socket first, makes it mode 0600. The fd, or -1.
int tfp_listen(const char *path, int backlog);

// Waits up to timeout_ms for a connection on listener, or for wake_fd to become readable (then returns -2).
// The accepted fd (SO_NOSIGPIPE, close-on-exec), -2 on wake, or -1 (errno ETIMEDOUT on timeout).
int tfp_accept(int listener, int wake_fd, int timeout_ms);

// The uid of the process on the other end of the Unix socket fd, or -1.
long tfp_peer_uid(int fd);

// Reads one line (up to '\n', which isn't kept) within timeout_ms. Its length, or -1 (ETIMEDOUT,
// EMSGSIZE when it doesn't fit in buflen - 1, ECONNRESET when the other side closed first).
long tfp_read_line(int fd, char *buf, size_t buflen, int timeout_ms);

// Writes all of buf. 0, or -1.
int tfp_write_all(int fd, const void *buf, size_t len);

#endif
