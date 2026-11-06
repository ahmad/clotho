#include "tailnet_fdpass.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// Waits until fd is readable (events = POLLIN) before deadline (ms, CLOCK_MONOTONIC). 0, or -1 (ETIMEDOUT).
static int wait_fd(int fd, short events, long long deadline) {
    for (;;) {
        long long left = deadline - now_ms();
        if (left <= 0) { errno = ETIMEDOUT; return -1; }
        struct pollfd p = { .fd = fd, .events = events };
        int r = poll(&p, 1, (int)(left > 60000 ? 60000 : left));
        if (r > 0) return 0;
        if (r < 0 && errno != EINTR) return -1;
    }
}

static void setup_fd(int fd) {
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
}

int tfp_send_fd(int sock, int fd) {
    char byte = 0;
    struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
    union { struct cmsghdr h; char buf[CMSG_SPACE(sizeof(int))]; } control;
    memset(&control, 0, sizeof control);
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = control.buf, .msg_controllen = sizeof control.buf };
    struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(c), &fd, sizeof(int));
    for (;;) {
        ssize_t n = sendmsg(sock, &msg, 0);
        if (n == 1) return 0;
        if (n < 0 && errno == EINTR) continue;
        if (n >= 0) errno = EIO;
        return -1;
    }
}

int tfp_recv_fd(int sock, int timeout_ms, char *buf, size_t buflen) {
    long long deadline = now_ms() + timeout_ms;
    if (wait_fd(sock, POLLIN, deadline) != 0) return -1;
    char data[512];
    struct iovec iov = { .iov_base = data, .iov_len = sizeof data - 1 };
    union { struct cmsghdr h; char buf[CMSG_SPACE(4 * sizeof(int))]; } control;
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = control.buf, .msg_controllen = sizeof control.buf };
    ssize_t n;
    do { n = recvmsg(sock, &msg, 0); } while (n < 0 && errno == EINTR);
    if (n < 0) return -1;
    int got = -1;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c != NULL; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS) continue;
        size_t count = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        for (size_t i = 0; i < count; i++) {
            int fd;
            memcpy(&fd, CMSG_DATA(c) + i * sizeof(int), sizeof(int));
            if (got < 0) got = fd; else close(fd);  // only one is expected
        }
    }
    if (got >= 0) {
        fcntl(got, F_SETFD, FD_CLOEXEC);
        return got;
    }
    if (n == 0) { errno = ECONNRESET; return -1; }
    if (buf != NULL && buflen > 0) {
        size_t k = (size_t)n < buflen - 1 ? (size_t)n : buflen - 1;
        memcpy(buf, data, k);
        buf[k] = 0;
    }
    return -2;
}

static int make_addr(const char *path, struct sockaddr_un *addr) {
    memset(addr, 0, sizeof *addr);
    addr->sun_family = AF_UNIX;
    if (strlen(path) >= sizeof addr->sun_path) { errno = ENAMETOOLONG; return -1; }
    strcpy(addr->sun_path, path);
    return 0;
}

int tfp_connect(const char *path) {
    struct sockaddr_un addr;
    if (make_addr(path, &addr) != 0) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    setup_fd(fd);
    int r;
    do { r = connect(fd, (struct sockaddr *)&addr, sizeof addr); } while (r < 0 && errno == EINTR);
    if (r != 0) { int e = errno; close(fd); errno = e; return -1; }
    return fd;
}

int tfp_listen(const char *path, int backlog) {
    struct sockaddr_un addr;
    if (make_addr(path, &addr) != 0) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    unlink(path);
    // Created 0600 from the start: no moment where another user could connect.
    mode_t old = umask(0177);
    int r = bind(fd, (struct sockaddr *)&addr, sizeof addr);
    umask(old);
    if (r != 0 || chmod(path, 0600) != 0 || listen(fd, backlog) != 0) { int e = errno; close(fd); errno = e; return -1; }
    return fd;
}

int tfp_accept(int listener, int wake_fd, int timeout_ms) {
    long long deadline = now_ms() + timeout_ms;
    for (;;) {
        long long left = deadline - now_ms();
        if (left <= 0) { errno = ETIMEDOUT; return -1; }
        struct pollfd p[2] = { { .fd = listener, .events = POLLIN }, { .fd = wake_fd, .events = POLLIN } };
        int r = poll(p, wake_fd >= 0 ? 2 : 1, (int)(left > 60000 ? 60000 : left));
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) continue;
        if (wake_fd >= 0 && (p[1].revents & (POLLIN | POLLHUP))) return -2;
        if (p[0].revents & (POLLERR | POLLNVAL)) { errno = EBADF; return -1; }
        if (!(p[0].revents & POLLIN)) continue;
        int fd = accept(listener, NULL, NULL);
        if (fd < 0) { if (errno == EINTR || errno == ECONNABORTED || errno == EAGAIN) continue; return -1; }
        setup_fd(fd);
        return fd;
    }
}

long tfp_peer_uid(int fd) {
    uid_t uid;
    gid_t gid;
    if (getpeereid(fd, &uid, &gid) != 0) return -1;
    return (long)uid;
}

long tfp_read_line(int fd, char *buf, size_t buflen, int timeout_ms) {
    long long deadline = now_ms() + timeout_ms;
    size_t used = 0;
    for (;;) {
        if (used + 1 >= buflen) { errno = EMSGSIZE; return -1; }
        if (wait_fd(fd, POLLIN, deadline) != 0) return -1;
        ssize_t n = read(fd, buf + used, 1);  // a byte at a time: nothing after the line is consumed
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        if (n == 0) { errno = ECONNRESET; return -1; }
        if (buf[used] == '\n') { buf[used] = 0; return (long)used; }
        used++;
    }
}

int tfp_write_all(int fd, const void *buf, size_t len) {
    const char *p = buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        p += n;
        len -= (size_t)n;
    }
    return 0;
}
