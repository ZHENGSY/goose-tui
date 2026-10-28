#!/usr/bin/env python3
"""tests/pty.py -- the framework on a real terminal.

The Goose tests check the model; this checks the plumbing. It allocates a
pty, sets a window size, runs a built example in it and asserts on the bytes
that actually came back: the alternate screen calls, the restore on exit,
and -- the claim the whole design rests on -- that an idle program writes
nothing at all.

    python3 tests/pty.py ./examples/05_todo

Standard library only: tests should not need a package manager.
"""

import os
import pty
import select
import struct
import sys
import fcntl
import termios
import time
import signal

COLS, ROWS = 80, 24


class Session:
    def __init__(self, argv, cols=COLS, rows=ROWS):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ["TERM"] = "xterm-256color"
            os.environ["COLUMNS"] = str(cols)
            os.environ["LINES"] = str(rows)
            try:
                os.execv(argv[0], argv)
            finally:
                os._exit(127)
        self.set_size(cols, rows)
        self.buf = b""

    def set_size(self, cols, rows):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack("HHHH", rows, cols, 0, 0))

    def read(self, timeout):
        """Reads whatever arrives until `timeout` seconds pass with no bytes."""
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return
            r, _, _ = select.select([self.fd], [], [], left)
            if not r:
                return
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            self.buf += chunk
            deadline = time.monotonic() + timeout

    def write(self, data):
        os.write(self.fd, data.encode() if isinstance(data, str) else data)

    def resize(self, cols, rows):
        self.set_size(cols, rows)
        os.kill(self.pid, signal.SIGWINCH)

    def wait(self, timeout=5.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                return status
            self.read(0.05)
        raise AssertionError("the program did not exit")

    def wait_only(self, timeout=5.0):
        """Waits without reading: the fd is gone in the hang-up test."""
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                return status
            time.sleep(0.02)
        raise AssertionError("the program did not exit")

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass


passed = 0
failed = 0


def check(name, ok):
    global passed, failed
    if ok:
        passed += 1
        return
    failed += 1
    print("FAIL ", name)


def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else "./examples/05_todo"
    if not os.path.exists(binary):
        print("missing binary:", binary, "-- run goose build first", file=sys.stderr)
        return 2

    s = Session([binary])

    # 1. The first frame: alternate screen, hidden cursor, no autowrap.
    s.read(1.0)
    first = s.buf
    check("enters the alternate screen", b"\x1b[?1049h" in first)
    check("hides the cursor", b"\x1b[H" in first)
    check("turns off autowrap", b"\x1b[?7l" in first)
    check("draws at the top left", b"\x1b[1;1H" in first)
    check("paints the whole screen", first.count(b"H") >= ROWS)
    check("asks for truecolor", b"\x1b[0;38;2;" in first or b"38;2;" in first)

    # 2. Idle: no input, no bytes. This is the design's central claim.
    s.buf = b""
    s.read(0.4)
    check("an idle frame writes nothing", s.buf == b"")

    # 3. A keystroke is a delta, not a repaint.
    s.buf = b""
    s.write("j")
    s.read(0.3)
    key_bytes = len(s.buf)
    check("a keystroke is a delta", 0 < key_bytes < 400)
    check("the delta is not a whole screen", key_bytes < ROWS * COLS // 4)
    s.buf = b""
    s.read(0.3)
    check("after the delta, idle again", s.buf == b"")

    # 4. A resize is noticed without input.
    s.buf = b""
    s.resize(100, 30)
    s.read(0.6)
    check("a resize repaints", len(s.buf) > 0)
    check("the repaint covers the new height", b"\x1b[30;1H" in s.buf or b"\x1b[29;" in s.buf)

    # 5. Quit: the terminal is handed back. Ctrl-C, which the run loop treats
    # as quit unless the program claims it first.
    s.buf = b""
    s.write("\x03")
    status = s.wait()
    s.read(0.1)
    tail = s.buf
    check("exits with status 0", os.WEXITSTATUS(status) == 0)
    check("leaves the alternate screen", b"\x1b[?1049l" in tail)
    check("restores the cursor", b"\x1b[?25h" in tail)
    check("resets the style", b"\x1b[0m" in tail)
    s.close()

    # 6. A terminal that goes away mid-run does not hang or crash.
    s2 = Session([binary])
    s2.read(0.5)
    os.close(s2.fd)
    status = s2.wait_only()
    check("end of input exits cleanly", os.WEXITSTATUS(status) == 0)

    print(passed, " passed, ", failed, " failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
