/* term.c -- the only platform-specific code in goose-tui.
 *
 * Six functions, each of which is a syscall or a libc table Goose does not
 * have. Everything else in the framework is Goose.
 *
 * The C boundary layouts (spec §7.10):
 *
 *   Goose                                C
 *   -----------------------------------  -------------------------------
 *   fn tui_read(buf: u8[:], ms: i32)      (sl_u8 {data,len}, int32_t)
 *   fn tui_write(s: const u8[:])          (sl_u8)
 *   fn tui_size(out: Size&)               (Size_g *out), Size = 2 x i32
 *
 * A Goose slice is a two-word struct { pointer, length }, which is why sl_u8
 * below is declared by hand: the compiler only puts types into goose.h that
 * C cannot spell, and this is one C can spell for itself.
 */

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <locale.h>
#include <sys/ioctl.h>

#include "goose.h"

typedef struct { uint8_t *data; int64_t len; } sl_u8;
typedef struct { int32_t rows; int32_t cols; } Size_g;

static struct termios g_saved;
static int g_opened = 0;
static int g_raw = 0;
static volatile sig_atomic_t g_restored = 0;

/* ---------------- low level output ---------------- */

static void write_all(const char *p, int64_t n) {
    while (n > 0) {
        ssize_t w = write(STDOUT_FILENO, p, (size_t)n);
        if (w < 0) {
            if (errno == EINTR) continue;
            return;
        }
        p += w;
        n -= w;
    }
}

static void write_str(const char *s) { write_all(s, (int64_t)strlen(s)); }

/* Leaves the terminal exactly as tui_open found it. Safe to call twice and
   from a signal handler: write(2) and tcsetattr are async-signal-safe, and
   the guard stops the second call from emitting the sequence twice. */
static void restore(void) {
    if (g_restored) return;
    g_restored = 1;
    write_str("\x1b[0m\x1b[?1000l\x1b[?1002l\x1b[?1006l\x1b[?7h\x1b[?25h\x1b[?1049l");
    if (g_raw) {
        tcsetattr(STDIN_FILENO, TCSANOW, &g_saved);
        g_raw = 0;
    }
}

static void on_signal(int sig) {
    restore();
    signal(sig, SIG_DFL);
    raise(sig);
}

/* ---------------- lifecycle ---------------- */

int32_t tui_open(void) {
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) return 0;
    if (!g_opened) {
        if (tcgetattr(STDIN_FILENO, &g_saved) != 0) return -1;
        g_opened = 1;
        atexit(restore);
        signal(SIGTERM, on_signal);
        signal(SIGHUP, on_signal);
        signal(SIGINT, on_signal);
        signal(SIGQUIT, on_signal);
        signal(SIGSEGV, on_signal);
        signal(SIGABRT, on_signal);
    }
    /* Everything the program printed through stdio must reach the terminal
       before the first escape sequence does. */
    fflush(stdout);
    fflush(stderr);

    struct termios raw = g_saved;
    cfmakeraw(&raw);              /* no echo, no line discipline, no ISIG */
    raw.c_cc[VMIN] = 0;           /* read returns what is there */
    raw.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0) return -1;
    g_raw = 1;
    g_restored = 0;

    write_str("\x1b[?1049h"        /* alternate screen */
              "\x1b[?25l"          /* hide the cursor */
              "\x1b[?7l"           /* no autowrap: the last column is ours */
              "\x1b[0m\x1b[2J\x1b[H");
    setlocale(LC_ALL, "");
    return 1;
}

void tui_close(void) { restore(); }

void tui_mouse(int32_t on) {
    if (on) write_str("\x1b[?1000h\x1b[?1002h\x1b[?1006h");
    else    write_str("\x1b[?1000l\x1b[?1002l\x1b[?1006l");
}

/* ---------------- geometry ---------------- */

int32_t tui_size(Size_g *out) {
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) != 0) return 0;
    if (ws.ws_col == 0 || ws.ws_row == 0) return 0;
    out->rows = (int32_t)ws.ws_row;
    out->cols = (int32_t)ws.ws_col;
    return 1;
}

/* ---------------- input ---------------- */

/* Waits up to timeout_ms for bytes. Returns the count, 0 on timeout, -1 at
   end of input or on a read error. Never blocks past the timeout, which is
   what lets the run loop tick animations and notice a resize. */
int32_t tui_read(sl_u8 buf, int32_t timeout_ms) {
    if (buf.len <= 0) return 0;
    struct pollfd p;
    p.fd = STDIN_FILENO;
    p.events = POLLIN;
    p.revents = 0;
    int r = poll(&p, 1, timeout_ms < 0 ? 0 : timeout_ms);
    if (r == 0) return 0;
    if (r < 0) return 0;                      /* EINTR: a frame boundary */
    ssize_t n = read(STDIN_FILENO, buf.data, (size_t)buf.len);
    if (n < 0) {
        if (errno == EINTR || errno == EAGAIN) return 0;
        return -1;
    }
    if (n == 0) return -1;
    return (int32_t)n;
}

/* ---------------- output ---------------- */

void tui_write(sl_u8 s) { write_all((const char *)s.data, s.len); }
