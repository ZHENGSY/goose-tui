# goose-tui — platform and terminal compatibility

Where the framework runs, what a terminal must implement for it to draw
correctly, and what a Windows port would actually cost. Everything here is
derived from the source rather than from intent: the file and line references
are the evidence.

The claim the design rests on: **`src/term.c` is 155 lines and every other
line — 2 268 of Goose — is platform-free.** No `#ifdef` appears anywhere in
the Goose, and no Goose file touches a file descriptor, an environment
variable or the OS clock except through `clock_ns()`.

Last verified: 2026-10-28, macOS 26.7.1 arm64, clang 21.0.0, goose runtime
`4d3da949e563` — `sh tests/run.sh` complete: 4 suites (260 assertions), 7
examples headless, 17 pty checks.

---

## 1. Summary

| host | status | rests on |
|---|---|---|
| macOS (arm64) | **supported**, tested end to end | `termios` · `poll` · `ioctl(TIOCGWINSZ)` · `write` · `signal` |
| Linux (glibc, musl), WSL2 | **supported**, same source as macOS | the same six calls; no Linux-only syscall anywhere |
| FreeBSD / OpenBSD / NetBSD, illumos | expected to compile, **untested** | `cfmakeraw` is BSD-derived; `struct winsize` and `TIOCGWINSZ` are the portable names |
| MSYS2 / Cygwin (`mintty`) | expected to run **unchanged**, untested | mintty is a real pty, so the POSIX layer applies; the binary links `msys-2.0.dll` |
| native Windows (conhost, Windows Terminal) | **not supported** | needs a second implementation of the six functions — §5 |
| stdin/stdout not a terminal (CI, pipes, `--dump`) | **supported** | `open` refuses (`term.c:79`); apps render with `tui::screen_text` |

There is no CI in this tree: `tests/run.sh` is the whole check, and it is a
POSIX shell script. §6 says which parts of it can run where.

---

## 2. The seam

Six `extern fn`s in `tui.goose:34-39`, six C functions in `src/term.c`:

| Goose | C | why not Goose |
|---|---|---|
| `tui_open` / `tui_close` | `isatty`, `tcgetattr`, `tcsetattr`, `cfmakeraw`, `signal`, `atexit` | no syscall, no `ioctl`, no signal handling in the language |
| `tui_size` | `ioctl(TIOCGWINSZ)` | same |
| `tui_read` | `poll` + non-blocking `read(0)` | no fd concept |
| `tui_write` | one `write(2)` per frame | must bypass stdio so an escape frame never interleaves with `print` |
| `tui_mouse` | `ESC[?1000h?1002h?1006h` bytes | plain bytes, but it keeps open/close symmetry in one place |

Nothing else crosses: no callback, no handle, no allocator, no state Goose
does not own (DESIGN §6). That is why portability here is one file and not an
architectural exercise.

---

## 3. The terminal contract

goose-tui does not read terminfo and never asks the terminal what it can do
(DESIGN §7). It emits this subset, and a terminal that speaks it gets a
correct picture:

| sequence | used for | emitted at |
|---|---|---|
| `ESC[?1049h` / `ESC[?1049l` | alternate screen in / out | `term.c:63`, `term.c:104` |
| `ESC[?7l` / `ESC[?7h` | autowrap **off** while open, on at exit | `term.c:63`, `term.c:106` |
| `ESC[2J` `ESC[H` | first clear and home | `term.c:107` |
| `ESC[?25h` / `ESC[?25l` | hardware cursor show / hide | `cell.goose:381-387` |
| `ESC[<row>;<col>H` | absolute cursor move, 1-based | `cell.goose:303-305` |
| SGR `0`, `1`, `2`, `3`, `4`, `5`, `7`, `9` | one sequence per style change, always starting at `0`: reset, bold, dim, italic, underline, blink, reverse, strike | `cell.goose:270-281` |
| SGR `38;5;n` / `48;5;n` | 256-colour foreground / background | `cell.goose:291-300` |
| SGR `38;2;r;g;b` / `48;2;r;g;b` | 24-bit | same |
| `ESC[?1000h?1002h?1006h` | SGR mouse reporting, opt-in via `set_mouse` | `term.c:114-116` |

Assumptions worth stating, because a "mostly ANSI" terminal can break them:

- **Absolute addressing over a fixed cell grid.** No scroll regions, no
  relative motion, no `DSR`/`CPR` query, no `DECRQSS`, no terminfo. If the
  terminal cannot place a glyph at (column, row), nothing else compensates.
- **DECAWM is honoured.** Autowrap is disabled so the presenter may write the
  last column of the last row without scrolling the screen. A terminal that
  ignores `?7l` will scroll one line per frame and desynchronise the front
  buffer.
- **No capability probing at all.** The framework never reads `TERM`,
  `COLORTERM` or `NO_COLOR`, and sends 24-bit SGR unconditionally. A
  256-colour emulator must approximate `38;2` itself (most do); a palette that
  must be exact can be built with `ansi(n)` and `theme_mono()`.
- **Width is computed in Goose, not by libc.** `utf8.goose` owns the table
  (DESIGN §6), so the answer does not depend on the process locale — but the
  terminal's font may still disagree about emoji and variation selectors.
  `setlocale(LC_ALL, "")` at `term.c:108` affects nothing in the framework.
- **Input is a byte stream.** The decoder (`keys.goose`) understands
  CSI/SS3 keys, `CSI u`, SGR mouse and `CSI 200~` … `CSI 201~` paste. The
  framework never *enables* bracketed paste — no `?2004h` is written anywhere
  — so in practice a paste arrives as ordinary bytes and is interpreted as
  keystrokes. See §8.

---

## 4. POSIX

### macOS and Linux

One file, no conditional compilation. The two behave identically because the
only calls used are POSIX, and the only runtime differences are ones the
framework does not depend on:

- one `write(2)` per frame, retried on `EINTR` (`term.c:43-53`);
- `poll` with `idle_ms` (default 50, `tui.goose:52`, `tui.goose:91`) is both
  the input wait and the animation tick — **there is no `SIGWINCH` handler**:
  a resize is noticed by the size check at the top of the next frame
  (`tui.goose:162-171`), so resize latency is bounded by the frame period;
- restore runs from `atexit` and from `SIGTERM`/`SIGHUP`/`SIGINT`/`SIGQUIT`/
  `SIGSEGV`/`SIGABRT` (`term.c:83-89`), using only `write` and `tcsetattr`,
  which are async-signal-safe — this is why an interrupted program does not
  leave a raw terminal behind.

A consequence of the 50 ms tick: 20 wakeups per second while nothing happens,
and an idle frame still writes **0 bytes** (asserted in `tests/diff.goose`).
Laptop and container users feel the first number, not the second.

### BSD and illumos

Nothing Linux-specific is used, so this should compile. The three things that
would fail first, in order:

1. `cfmakeraw` — BSD in origin, present on macOS, glibc, musl and the BSDs;
   Solaris/illumos historically expose equivalent flags but not always the
   helper.
2. `struct winsize` and `TIOCGWINSZ` — on some System V derivatives they live
   in `<termios.h>` rather than `<sys/ioctl.h>`, so an include may be needed.
3. `poll` — universal on POSIX; no `epoll`/`kqueue` path exists to diverge.

A failure here fails at compile time, in one file. That is the property the
design is buying.

### WSL, SSH, tmux, screen

- **WSL2** is Linux; nothing changes.
- **SSH** works as long as the remote `TERM` is xterm-ish in practice. The
  framework never reads `TERM`, so it will also emit escapes into a terminal
  that cannot parse them — see §8.
- **tmux / screen** present a pty, so `isatty`, raw mode and
  `TIOCGWINSZ` all work, and the alternate screen is supported. 24-bit SGR may
  be flattened unless tmux is configured to pass it through
  (`terminal-overrides` / `terminal-features`); the framework neither detects
  this nor compensates.
- **Serial consoles and `TERM=dumb`** are the honest hole: `isatty` is true,
  so `open` succeeds, and a non-ANSI device receives the escape stream
  verbatim. There is no capability check to fall back on, by design.

---

## 5. Windows

### 5.1 Status

Not supported, deliberately and in writing: README "Portability", DESIGN §8
("A Windows port is a second implementation of the same six functions"),
DESIGN §9 ("Not delivered, deliberately: … Windows"). This is an absent
backend, not a bug.

### 5.2 What already works on Windows

- **The toolchain.** `goose toolchain --cc msvc|clang-cl` is a supported
  compiler choice, and the Goose runtime carries 33 `_WIN32` branches; the
  language runs natively.
- **Every line above the seam.** `cell.goose`, `rect.goose`, `utf8.goose`,
  `keys.goose`, `theme.goose`, `widgets.goose` and the draw loop in
  `tui.goose` do no I/O. `clock_ns()` is a runtime intrinsic, not a libc call.
- **The headless tests.** `units`, `decoder`, `widgets` and `diff` never touch
  a terminal: they render into a canvas and compare text or escape bytes.
  They can run on Windows today with no change.
- **What cannot move:** `tests/pty_test.py` (`pty`, `fcntl`, `termios`) and
  `tests/run.sh` (POSIX shell). A Windows test harness is ConPTY
  (`CreatePseudoConsole`, Windows 10 1809+) or nothing.

### 5.3 The six functions, mapped

| `term.c` now | Win32 replacement | the part that is not mechanical |
|---|---|---|
| `tcgetattr`/`tcsetattr` + `cfmakeraw` | `GetConsoleMode`/`SetConsoleMode`: `ENABLE_VIRTUAL_TERMINAL_PROCESSING`, `DISABLE_NEWLINE_AUTO_RETURN`, `ENABLE_VIRTUAL_TERMINAL_INPUT` | VT output is Windows 10 1511+; **VT input is 1809+** |
| `poll(fd 0, ms)` | `WaitForSingleObject(hStdin, ms)` | works for a console handle; stdin as a **pipe** needs `PeekNamedPipe`, so "one read per frame" must be re-expressed per handle kind |
| `read(fd 0)` raw bytes | `ReadFile` in VT input mode yields the same escape stream | outside VT mode: `ReadConsoleInputW` + `INPUT_RECORD`, translated into the byte stream `keys.goose` already parses — **the largest piece of the port** |
| `ioctl(TIOCGWINSZ)` | `GetConsoleScreenBufferInfo` → `srWindow` | the *window*, not the buffer; the alternate buffer has its own size, and conhost reflows on resize |
| `write(2)` UTF-8 bytes | `WriteFile` + `SetConsoleOutputCP(CP_UTF8)`, or `WriteConsoleW` + UTF-16 | code page: UTF-8 through `WriteFile` is cheapest but shares the code page with the app's own `print`; `WriteConsoleW` is correct but needs a UTF-8→UTF-16 conversion of every frame's diff — a buffer and a copy the POSIX path does not have |
| `signal(SIGTERM, SIGHUP, SIGQUIT, SIGSEGV, SIGABRT)` + `atexit` | `SetConsoleCtrlHandler` (Ctrl-C, Ctrl-Break, close, logoff, shutdown) + `SetUnhandledExceptionFilter` for faults | no `SIGSEGV` equivalent; `CTRL_CLOSE_EVENT` gives the handler a few seconds (5 by default) before the process is killed, so a restore that blocks leaves a raw console behind |

### 5.4 Where the work actually is

In descending order of cost:

1. **Input translation.** If the port targets Windows 10 1809+ and the
   terminal in use is Windows Terminal or conhost with VT input, the existing
   `keys.goose` works untouched. Below that, or to support
   `ReadConsoleInputW`, the decoder's input contract has to be reproduced in C
   — a second implementation of the same shape, which is exactly what the
   six-function boundary was meant to prevent.
2. **Output encoding.** UTF-8 via `WriteFile` is a code-page decision shared
   with the rest of the process; `WriteConsoleW` costs a conversion per frame
   and touches the "zero allocation, tens of bytes per keystroke" property.
3. **Teardown.** Alternate screen, hidden cursor and raw mode must be undone
   from a console control handler and an unhandled-exception filter. This is
   where a partial port feels worse than no port: a crash that leaves the
   console in raw mode and the cursor invisible is user-visible damage.
4. **Waiting.** `poll` has no single equivalent; the timeout, the "0 bytes
   means tick" convention and `EINTR`-as-frame-boundary all have to be
   re-derived.
5. **Geometry and newline.** `DISABLE_NEWLINE_AUTO_RETURN` matters because the
   presenter positions the cursor itself; without it, writing the last column
   of the last row can scroll.

### 5.5 Build plumbing

Every `c_*` key in a Goose sidecar takes a `_windows`, `_linux` or `_macos`
suffix (Goose's `docs/packages.md`). A port is therefore a sibling file and one
extra line — not an `#ifdef`, and not a second build description:

```goose
c_sources = ["src/term.c"];
c_sources_windows = ["src/term_win32.c"];
```

DESIGN §8 calls the port "a second implementation of the same six functions";
this keeps that honest: two files, one build description, one boundary. What it
costs is a second backend to keep in step — every change to the contract (the
`open`/`close` symmetry, the restore path) now has two readers.

### 5.6 Cost

| item | size |
|---|---|
| headless tests on Windows | 0 lines |
| `term_win32.c` (VT path, INPUT_RECORD fallback) | **250–450 lines of C** — the largest source file after `widgets.goose` |
| UTF-8 → UTF-16 output path | tens of lines, one buffer |
| ConPTY test harness replacing `pty_test.py` | ~100 lines, Windows 10 1809+ only |
| docs and version floor | — |

Roughly 1–3 days for someone with a Windows machine and one target terminal;
substantially more if Windows 7/8 must work, because that removes the VT path
and leaves the `INPUT_RECORD` translation as the only implementation.

### 5.7 Two traps

- **MinGW-w64 is not the native path.** It does not give you POSIX termios
  and a meaningful `TIOCGWINSZ`; where a `termios.h` shim exists it can accept
  the calls and do nothing, which is the worst outcome: it compiles, raw mode
  never engages, keys echo and the screen doubles.
- **MSYS2 / Cygwin is the opposite.** mintty is a pty, so the existing
  `term.c` may work with no change — but the result depends on
  `msys-2.0.dll`, is not a native executable, and interops poorly with
  programs launched from it.

---

## 6. Testing matrix

| check | macOS | Linux | BSD | MSYS2 | native Windows |
|---|---|---|---|---|---|
| `goose check` on the seven files | yes | yes | yes | yes | yes |
| `units`, `decoder`, `widgets`, `diff` | yes | yes | yes | yes | yes — **nothing to port** |
| examples with `--dump` (headless) | yes | yes | yes | yes | yes |
| `tests/pty_test.py` (real pty lifecycle) | yes | yes | yes | yes (msys pty) | no — ConPTY harness needed |
| `tests/run.sh --quick` | yes | yes | yes | maybe (`sh` present) | no |

`sh tests/run.sh --quick` is therefore the portable check: it is everything
above except the example builds and the pty test, and it needs only Goose.

---

## 7. What a port must preserve

Any backend, present or future, is only correct if these hold:

1. **An idle frame writes 0 bytes.** (`tests/diff.goose`)
2. **One write per frame**, so escapes never interleave with `print`.
3. **Restore on every exit path** — normal close, signal, and (on Windows)
   console control / unhandled exception. Idempotent, as `restore()` is.
4. **Refuse when stdout is not a terminal**; the caller falls back to
   `screen_text`.
5. **Width stays in Goose.** A backend that starts calling `wcwidth` makes
   rendering depend on locale, which is the bug DESIGN §6 exists to avoid.
6. **The boundary stays six functions.** No allocator, no handle, no callback
   crosses it.

---

## 8. Known limits

- **Bracketed paste is decoded but never enabled.** `keys.goose:200-221`
  handles `CSI 200~` … `CSI 201~`, and `term.c` writes no `?2004h`, so
  terminals that only emit those markers when asked will deliver a paste as
  keystrokes. Enabling it is one sequence in `open` and its counterpart in
  `restore`.
- **No capability probing of any kind.** `TERM`, `COLORTERM` and `NO_COLOR`
  are never read; 24-bit SGR is always emitted; degradation is the emulator's
  job or the application's choice of theme.
- **No focus events** (`?1004`), no clipboard (`OSC 52`), no images
  (sixel / kitty) — DESIGN §9.
- **Terminfo is deliberately absent**, so a tty that is not ANSI (serial
  console, `TERM=dumb`, a broken emulator) is detected as "a terminal" by
  `isatty` and then receives escapes it cannot parse. The failure mode is
  visible garbage, not a crash.
- **The 50 ms idle tick** costs 20 wakeups per second even when nothing
  happens. A backend or a future loop could block indefinitely and wake on
  input plus a timer, but that changes frame pacing and the `Event.None`
  contract.
- **Native Windows is absent**; the port plan is §5.
