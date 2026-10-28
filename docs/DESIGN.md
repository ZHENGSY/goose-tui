# goose-tui — design and technical path

A terminal UI framework written in Goose: cell-buffer rendering with damage
diffing, an immediate-mode widget model, and app-owned state.

This document is the argument. It says what the framework does, why each
choice is the one Goose can execute best, and what the alternatives cost.

---

## 1. The shape of the problem

A terminal UI has six jobs:

1. put the terminal in raw mode, restore it whatever happens;
2. turn bytes into key, mouse, paste and resize events;
3. decide where things go (layout);
4. turn widgets into a grid of cells;
5. turn that grid into as few escape sequences as possible;
6. own application state.

Jobs 1 and 2's syscalls, 3–5, and 6 are different kinds of work, and the
language should be chosen per job rather than for the whole program. Goose
covers 2–6 (the parsing, the arithmetic, the state) better than C does, and
covers 1 not at all. So the boundary sits exactly there: **155 lines of C
behind six `extern fn`s — `open`, `close`, `size`, `read`, `write`, `mouse` —
and everything above it written in Goose.**

```
        your app  (Goose: state, keys, layout, widgets)
            |
   tui widgets        text · panel · list · table · input · tabs · gauge
            |
     cell canvas       Cell[>..]  back buffer, one flat array
            |
   diff + presenter    compare with the front buffer, emit escapes
            |
   term (Goose)  --->  tui_* extern fns  --->  term.c (POSIX)
                                                 termios · poll · ioctl
                                                 write · signals
```

## 2. Why immediate mode and not a widget tree

Every framework in the reference set (`FTXUI`, `cview`, `opentui`,
`notcurses`) eventually separates "what should be on screen" from "what is on
screen". They differ in *how the first one is described*:

| model | example | what it needs from the language |
|---|---|---|
| retained tree of objects | cview, opentui, GTK | heap nodes, trait objects / vtables, per-node dynamic strings |
| retained z-ordered planes | notcurses | allocation per plane, external ownership |
| **immediate mode: widgets are function calls** | FTXUI, Nuklear, ratatui | nothing beyond functions and structs |

Goose has **no heap, no `Box`, no `dyn`, no trait objects, and no resizable
array element**. A retained tree is therefore not merely inconvenient in
Goose, it is unrepresentable without building a pool + relative links + an
index-based parent/child/sibling scheme *inside* the framework — and pool
elements must be fixed-size, so every node's text would have to be a bounded
`u8[..N]` or a slice into a slab. That is a large amount of machinery whose
only purpose is to imitate an ownership model Goose deliberately does not
have.

Immediate mode deletes the tree. A widget is a function:

```goose
tui::text(c, body, "hello", th.fg);
tui::panel(c, side, " Files ", th);
tui::list(c, body, list_state, files, th);
```

There is no node object, no parent pointer, nothing to free, nothing whose
lifetime must be reasoned about. The frame is a sequence of calls; what
survives between frames is *your* struct. This is the same contract as
Nuklear, which Goose's own stdlib already ships as `ui`: *"An immediate-mode
program says each frame which windows and widgets there are… the program's
data stays its own, passed in by reference where a widget edits it."*
Framework and stdlib agree, so a Goose programmer learns one model, not two.

The cost of immediate mode is that you redraw everything each frame instead
of only the widget that changed. On a cell grid that cost is a few thousand
`Cell` stores — which is why the next section exists.

## 3. Rendering: one flat cell array, two buffers, one diff

```goose
struct Cell { ch: u32, fg: u32, bg: u32, attr: u16, flags: u8 }
struct Canvas { w: i32, h: i32, cells: Cell[>..] }
```

`cells.len == w * h`, and the cell at `(x, y)` is `cells[y * w + x]`. That is
the layout Goose renders fastest: one contiguous run of 16-byte records, one
bounds check per access, no pointer chasing. It is also the layout a terminal
actually is.

Goose's "a struct holds exactly one resizable, and it must be the last field"
rule would look like an obstacle here — the renderer wants three growables
(back buffer, front buffer, output bytes). It turns out to be a good
constraint, because **only one of the three is state**:

- the **back buffer** is the user's `Canvas`, sized to the terminal, rebuilt on
  resize;
- the **front buffer** (what the terminal currently shows) and the **output
  builder** are locals of the run loop, created once when the loop starts.

```goose
fn run<F>(app: App&, t: Term&, c: Canvas&) {
    var front: Cell[>..] = [];     // what the terminal shows
    var out: u8[>..] = [];         // this frame's escape sequences
    ...
}
```

Nothing about the diff needs a second struct field, so the rule costs nothing.

**The diff.** Each frame walks the two buffers once:

- equal cell → emit nothing (an idle frame writes **0 bytes**);
- changed cell → `CUP` only when the cursor is not already there, `SGR 0` plus
  the style only when the style changed, then the UTF-8 bytes;
- a wide (width-2) character occupies two cells: the head carries the code
  point, the tail is a marker, and the pair is written or skipped as a unit;
- the hardware cursor is moved last, and only when it moved or when cells were
  written under a visible caret, then the frame is written with **one
  `write(2)`**;
- an idle frame writes **0 bytes**, and hides nothing, so the caret does not
  flicker.

Measured by `tests/diff.goose` on this machine, 80×24, a panel + list + status
bar:

| frame | bytes |
|---|---|
| first frame (paints every cell) | 4094 |
| idle frame (nothing changed) | 0 |
| one glyph changed | 50 |
| the caret moved, no glyph changed | 7 |

A naive "print the whole grid every frame" implementation would pay the 4094
on every frame and flicker over ssh. Note what the 50 is: one `CUP` (6), one
`SGR` with two truecolour components (33), the glyph (1), plus the rest of the
escape. Style state is tracked only within a frame, so the first write of a
frame carries a full `SGR`; that is the price of not assuming what the
terminal's last style was.

## 4. Events: a byte state machine, not a `getch` switch

Input arrives as a stream, not as keys. `ESC` is either Escape or the start of
a sequence; `ESC [ A` is Up; `ESC [ 1 ; 5 A` is Ctrl-Up; `ESC [ <0;12;5M` is a
mouse press; a paste is bracketed by `ESC[200~ … ESC[201~`; and a Chinese
character is three bytes that must be decoded as one code point.

The decoder is one struct and one loop:

```goose
struct Decoder {
    state: u8, esc_at: i64,              // ground / esc / csi / ss3 / utf8 / paste
    params: u8[..24], np: i32,
    cp: u32, need: u8, seen: u8, mods: u8,
    paste: u8[..256], npaste: i32,       // bracketed paste accumulator
}
fn feed<F>(d: Decoder&, bytes: u8[:], now_ms: i64) { ... }   // F(ev) per event
```

A byte-at-a-time state machine is allocation-free, resumable across `read()`
boundaries, and testable: `feed` takes bytes, so a test feeds it the exact
bytes a terminal sends without needing a terminal. That is what `tests/` does.

`feed` reports events through a **trailing block**, so nothing is queued and
nothing is allocated:

```goose
feed(dec, buf[..n], now) { ev => F(c, ev) };
```

Blocks are compile-time and inline, so this is a plain loop with a call in it.

The lone-`ESC` timeout is the one place a clock is needed: the decoder records
when it saw `ESC`, and `flush(d, now)` is called after each read so a bare
Escape arrives once 25 ms have passed with no more bytes — the same call
resolves a UTF-8 sequence that stopped midway into one replacement character.

## 5. State: yours, on the stack, with no ownership ceremony

There is no `Context` object holding your data and no `&mut` through a tree.
The run block sees the enclosing function's locals directly:

```goose
fn main() {
    var t = tui::term();
    if !tui::open(t) { print("not a terminal"); return; }
    var app = tui::app();
    var c = tui::canvas(t.w, t.h);
    var tabs_st = tui::tabs_state();
    let labels: const u8[:][3] = ["inbox", "today", "later"];
    var lines = tui::input_new();

    tui::run(app, t, c) { cv, ev =>
        if tui::key_is(ev, 'q') { tui::quit(app); }
        tui::tabs_key(tabs_st, ev, 3);
        tui::tabs(cv, tui::rect(0, 0, cv.w, 1), tabs_st, labels, app.theme);
        let body = tui::rect(0, 2, cv.w, cv.h - 3);
        tui::panel(cv, body, "later", app.theme);
        tui::input_key(lines, ev);
        tui::set_cursor(app, tui::input(cv, tui::inset(body, 1), lines, true, app.theme));
    };
    tui::close(t);
}
```

`tabs_st` is a one-field struct on the stack. That is the entire "widget state"
story: nothing is registered, nothing is looked up by id, and the block closes
over the locals it needs.
Widgets that need more (a list's scroll offset, an input's caret) are small
fixed structs you declare next to it and pass by reference; a text field's
buffer is a `u8[>..]` you own, and the widget edits bytes in place.

This is why the framework has **no lifetime annotations anywhere**: nothing
owns a reference to anything else. The compiler's root analysis has nothing to
prove beyond the frame.

## 6. C: exactly six functions, and why each one must be C

| `extern fn` | why it cannot be Goose |
|---|---|
| `tui_open` / `tui_close` | `termios` — Goose has no `ioctl` and no way to make a syscall |
| `tui_size` | `TIOCGWINSZ` — same |
| `tui_read` | `poll` + non-blocking `read` on fd 0 |
| `tui_write` | one `write(2)` per frame; bypasses stdio so escape frames never interleave with `print` |
| `tui_mouse` | mouse-mode escapes are plain bytes — but this is where `open`/`close` symmetry is kept |

Display width is *not* on this list, and that is deliberate. `wcwidth` from
libc answers in the process locale, which a program may never have set (and
which may be `C`, where every CJK glyph measures -1). A width that disagrees
with the terminal's misplaces every glyph after it and desynchronises the
front buffer, so `utf8.goose` owns the table: sorted ranges for the East Asian
Wide/Fullwidth classes and the zero-width combining marks, plus a binary
search. It is ~90 lines of data, it is the same answer on every machine, and
it is a pure function over a constant — exactly the kind of thing Goose should
hold rather than delegate.

Alignment is checked at the boundary: a Goose slice crosses as
`{ data, len }`, so the shim declares

```c
typedef struct { uint8_t *data; int64_t len; } sl_u8;   // same layout
```

and a struct out-parameter crosses as a pointer. Both are verified in
`src/term.c`'s comments.

Nothing else crosses. No callbacks, no handles, no allocator, no state that
Goose does not own.

## 7. What was rejected, and what it would have cost

| alternative | why not |
|---|---|
| **Retained widget tree** | no heap / no `dyn` / resizable-not-an-element → pool + relative links + fixed-size nodes; every node's text becomes a bounded array. 3–5× the code, and the user still has to learn the framework's ownership rules. |
| **Direct writes, no cell buffer** (moonTUI, AnsiKit) | no diffing → flicker, 20 KB/frame, and no way to test what is on screen. |
| **Full redraw each frame, no diff** | correct but 100-1000× the bytes; idle frames cost the same as busy ones. |
| **Full flexbox / constraint solver** (FTXUI, opentui) | a two-pass solver over a tree of nodes. Without a tree, proportional `Rect` splitting covers the same UIs with `split_h`/`split_v`/`split_w`. |
| **Terminfo database** | a capability table is a portability layer for terminals that no longer exist. We emit the ANSI/xterm subset that every modern terminal speaks, and degrade cleanly (colors as 256 or 16 when truecolor is absent). |
| **Signals for resize** | `poll` with a frame timeout already bounds resize latency by one frame; a self-pipe + handler adds async state for no user-visible gain. |
| **A separate global terminal object** | globals in Goose are copied per thread and hidden from the reader. One `Term` value on the stack, passed by reference, keeps it visible. |

## 8. Consequences the user will feel

- **Zero allocation.** A frame is stores into a `Cell[>..]`; no allocator
  runs, no GC pauses, no fragmentation. Steady-state memory is the two cell
  buffers plus your state.
- **Startup is the binary.** No runtime, no terminfo files, no config.
- **Testable without a terminal.** `tui::screen_text(c)` dumps the canvas as
  plain text, so widget tests are golden comparisons; `tui::present` writes
  into a `u8[>..]`, so the diff tests assert on escape bytes; `tui::headless`
  feeds keystrokes to the real draw block, so examples are testable; and
  `tests/pty_test.py` drives a built binary under a real pty to check the
  terminal lifecycle itself.
- **Portability is one file.** `src/term.c` is the only OS-specific code;
  macOS and Linux share it. A Windows port is a second implementation of the
  same six functions; `docs/platforms.md` maps each call to its Win32
  replacement and prices the work.
- **The limits are honest.** Text inside a frame is `const u8[:]` views; a
  widget that must keep text (an input field, a log) owns it as a `u8[>..]`
  that you declare. There is no layout engine that measures text for you —
  `tui::para` wraps to the rect it is given and returns the height it used.

## 9. Scope of this implementation

Delivered:

- terminal lifecycle: raw mode, alternate screen, cursor, mouse (opt-in),
  bracketed paste, panic/signal restore;
- truecolor / 256 / 16 / default colours, bold, dim, italic, underline,
  reverse, strikethrough; wide-character and combining-mark cells;
- damage-diff presenter with cursor and style elision;
- layout: rect arithmetic, rows/columns, weighted splits, insets, centring;
- widgets: `text`, `para`, `ellipsis`, `panel`, `panel_focus`, `list`,
  `table`, `tabs`, `input`, `gauge`, `spark`, `scrollbar`, `log_view`,
  `status`, `help`, `hr`, `vr`, `focus`; key handling for list, table, tabs,
  input and focus;
- event decoder: keys with modifiers, arrows/home/end/pgup/pgdn/ins/del/F1-12,
  UTF-8, SGR mouse, bracketed paste, resize, lone-ESC timeout;
- themes (`dark`, `light`, `mono`, `nord`) as flat structs, and the `th_*`
  accessors that turn one into a `Style`;
- docs: guide, API reference, this design note, and the platform report
  (`docs/platforms.md`); 7 runnable examples (`01_hello` … `07_theme`);
- tests: 4 Goose suites (260 assertions: geometry, cells, widths, decoder,
  widget goldens, diff bytes) and `tests/pty_test.py` (17 checks on a real
  pty), all driven by `tests/run.sh`.

Not delivered, deliberately: flexbox, text measurement before drawing, word
wrap inside narrow tables, images, sixel/kitty graphics, Windows
(`platforms.md` §5).
