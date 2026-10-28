# goose-tui guide

From an empty file to a working program, in the order you actually need things.
Every snippet here is valid Goose and compiles against this package.

- [1. The four objects](#1-the-four-objects)
- [2. Drawing](#2-drawing)
- [3. Events](#3-events)
- [4. State and widgets](#4-state-and-widgets)
- [5. Text input](#5-text-input)
- [6. Layout](#6-layout)
- [7. Animation](#7-animation)
- [8. Testing without a terminal](#8-testing-without-a-terminal)
- [9. Writing your own widget](#9-writing-your-own-widget)
- [10. Goose habits that matter here](#10-goose-habits-that-matter-here)

---

## 1. The four objects

```goose
import std;
import tui from "you/goose-tui@v0.1.0";   // or a checkout: "../goose-tui"

fn main() {
    var t = tui::term();          // the terminal: size, raw mode, one read per frame
    if !tui::open(t) {            // false when stdout is not a terminal
        print("run me on a terminal");
        return;
    }
    var app = tui::app();         // running flag, theme, caret, frame clock
    var c = tui::canvas(t.w, t.h);

    tui::run(app, t, c) { cv, ev =>
        // draw everything here
        tui::text(cv, tui::rect(0, 0, cv.w, 1), "hello", tui::th_text(app.theme));
        if tui::key_is(ev, 'q') { tui::quit(app); }
    };

    tui::close(t);                // restores the screen even if the block never did
}
```

`tui::run` is a loop. Each pass:

1. notices a resize, resizes the canvas, delivers `Event.Resize`;
2. reads whatever input is waiting and delivers **one event per event**;
3. if nothing arrived, delivers `Event.None` so animations can tick;
4. diffs the canvas against what the terminal shows and writes the delta.

Your block draws; the loop decides what reaches the terminal.

`tui::close` is not optional bookkeeping — call it, or the terminal stays in raw
mode. (A signal or a panic restores it too; a normal return does not.)

**Why `tui::open(t)` and not `t.open()`?** Goose's uniform call syntax resolves
methods from the current namespace only, and `Term` lives in `tui`. Every
function in this package is called the same way, namespace first, so there is
one rule to remember.

## 2. Drawing

Everything is expressed in `Rect`s. A `Rect` is `{x, y, w, h}` in cells, and
every draw call clips to the rect it is given.

```goose
let th = tui::theme_dark();
let screen = tui::rect(0, 0, c.w, c.h);

let inner = tui::panel(c, screen, "files", th);   // border + title, returns the inside
tui::text(c, inner, "first line", tui::th_text(th));
tui::text_at(c, inner, inner.x + 2, inner.y + 2, "indented", tui::th_dim(th));
tui::hr(c, inner, inner.y + 3, tui::th_border(th));
tui::centered(c, tui::rect(inner.x, inner.y + 4, inner.w, 1), "middle", tui::th_text(th));
tui::ellipsis(c, inner, inner.x, inner.y + 5, "a very long path that will not fit", tui::th_text(th));
```

Colours are `u32`s with three forms, and a `Style` is a colour pair plus an
attribute bit set:

```goose
let plain  = tui::style(tui::ansi(200));                 // 256-colour index
let fancy  = tui::style(tui::rgb(130, 190, 255));        // 24-bit
let same   = tui::style(tui::rgb(1, 2, 3));              // same, spelled for the reader
let bolded = tui::bold(fancy);
let soft   = tui::without_attr(bolded, tui::ATTR_BOLD);
```

`tui::COLOR_DEFAULT` means "the terminal's own colour", and is what a theme's
background usually is. The encoder degrades: a terminal that ignores
`38;2;r;g;b` still draws the glyph.

Measure before you place:

```goose
let w = tui::text_width("中文");     // 4, not 6 and not 2
```

## 3. Events

`ev` is one `Event`. The helpers are all you normally need:

```goose
if tui::key_is(ev, 'q') { ... }                        // q, no modifiers
if tui::key_is_ctrl(ev, 's') { ... }                   // Ctrl-S
if tui::key_is_any(ev, tui::Key.Enter) { ... }         // named keys
if tui::is_mouse(ev) { let m = tui::mouse_of(ev); }    // m.x, m.y, m.button, m.kind
if tui::is_paste(ev) { tui::paste_append(ev, buf); }   // append bytes to yours
if tui::is_resize(ev) { ... }                          // w, h already applied to the canvas
```

A match reads best when you need the payload:

```goose
match tui::key_of(ev) {
    Char ch => { use(ch.cp); },
    Up => { scroll(); },
    _ => {},
}
```

Ctrl-C quits by default; set `app.quit_on_ctrl_c = false` if your program has
its own meaning for it.

**Paste** arrives as `Event.Paste` with its bytes inline (up to 256 at a time;
a longer paste is several events). The bytes do not outlive the frame, so copy
them if you keep them:

```goose
var draft: u8[>..] = [];
tui::paste_append(ev, draft);
```

**Mouse** is off by default so the terminal's own text selection keeps working.
Turn it on and you get press, release, drag and wheel events with cell
coordinates:

```goose
tui::set_mouse(t, true);
```

## 4. State and widgets

State is yours, on the stack, and widgets that need memory take a small struct
by reference. Nothing is registered and nothing is looked up by id.

```goose
let items: const u8[:][4] = ["inbox", "drafts", "sent", "trash"];
var st = tui::list_state();

... tui::run(app, t, c) { cv, ev =>
    tui::list_key(st, ev, 4);
    let side = tui::rect(0, 0, 20, cv.h);
    tui::panel(cv, side, "mail", app.theme);
    tui::list(cv, tui::inset(side, 1), st, items, app.theme);
};
```

Each widget has a matching `_key` function that returns `bool` — true when it
consumed the event — so several widgets can be offered the same keystroke in
priority order:

```goose
if !tui::input_key(field, ev) { tui::list_key(st, ev, items.len); }
```

A text field owns its buffer, so it is a resizable and must be the **last**
field of whatever struct holds it:

```goose
struct State {
    sel: i64,
    field: tui::Input,      // its text: u8[>..] — last, always
}
```

## 5. Text input

```goose
var field = tui::input_new();
tui::input_set(field, "initial text");       // caret to the end

... tui::run(app, t, c) { cv, ev =>
    tui::input_key(field, ev);               // arrows, home/end, backspace, delete, typing
    let r = tui::rect(2, 2, 30, 1);
    tui::set_cursor(app, tui::input(cv, r, field, true, app.theme));
};
```

`tui::input` returns a `Cursor`. Pass it to `tui::set_cursor` and the loop puts
the hardware cursor there; leave it alone and the caret stays hidden. The
caret moves by **code point**, and the visible window scrolls so the caret
stays inside the rect — type more than the field is wide and it still works.

## 6. Layout

Layout is arithmetic on rectangles. There is no solver, no flex model and no
second pass.

```goose
let top, body = tui::split_v(screen, 1);              // a title bar
let body2, foot = tui::split_v(body, body.h - 1);      // a status bar
let side, main = tui::split_h(body2, 24);              // a sidebar
let a, rest = tui::split_hw(main, 1, 3);               // a quarter
let row = tui::row_at(body2, 2, 5);                    // row 2 of 5
let card = tui::center(screen, 40, 10);                // a dialog
```

Splits clamp: `split_h(r, -10)` gives a zero-width left rect and the whole
width on the right, never a negative one. That means layout math never needs
guards, and a tiny terminal degrades rather than panicking.

The idiomatic shape for a screen is one function that draws it from scratch:

```goose
fn draw(c: tui::Canvas&, st: State, th: tui::Theme) { ... }
```

called every frame. Redrawing is cheap — a few thousand `Cell` stores — and the
presenter makes it invisible to the terminal.

## 7. Animation

`Event.None` means "nothing happened, here is a frame anyway". `app.now_ms` is
the clock, and `app.frames` counts frames:

```goose
... { cv, ev =>
    let t = (app.now_ms % 2000) as f64 / 2000.0;
    tui::gauge(cv, tui::rect(0, 0, cv.w, 1), t, "loading", app.theme);
};
```

The loop's idle timeout (`t.idle_ms`, 50 ms by default) is the frame interval.
Lower it for smoother animation and a busier CPU; the presenter still writes
nothing when the picture does not change, so an animation that has settled
costs nothing.

## 8. Testing without a terminal

Three levels, all used by this package's own tests:

```goose
// 1. a golden screen: draw, then read the cells back as text
var c = tui::canvas(40, 6);
tui::canvas_clear(c, tui::th_text(tui::theme_dark()));
tui::panel(c, tui::rect(0, 0, 40, 6), "hi", tui::theme_dark());
assert(tui::screen_text(c) == """…""");

// 2. the bytes: present into a buffer and look at the escapes
var front: tui::Cell[>..] = [];
var out: u8[>..] = [];
var shown = tui::cursor_hidden();
tui::present(out, c, front, tui::cursor_hidden(), shown);
assert(out.len > 0);
tui::present(out, c, front, tui::cursor_hidden(), shown);
assert(out.len == 0);                      // a second identical frame writes nothing

// 3. a whole program: feed it keystrokes and look at the last frame
var app = tui::app();
tui::headless(app, c, "jj\r", 3) { cv, ev => draw(cv, ev) };
print(tui::screen_text(c));
```

`tests/pty_test.py` is the fourth level: a real pty, a real binary, assertions
on the escape stream (alternate screen, deltas, resize, restore). Run the lot
with `sh tests/run.sh`.

## 9. Writing your own widget

A widget is a function over a `Rect`. It reads the state it is given, writes
cells, and returns whatever the caller needs — a height, a hit rect, a caret.

```goose
// A labelled field: a dim label, then the value, both inside `r`.
fn field(c: tui::Canvas&, r: tui::Rect, label: const u8[:], value: const u8[:], th: tui::Theme) {
    let lw = tui::text_width(label);
    tui::draw_text(c, r, r.x, r.y, label, tui::th_dim(th));
    tui::draw_text(c, r, r.x + lw + 1, r.y, value, tui::th_text(th));
}
```

Rules the shipped widgets follow, and yours should too:

- clip every write to the rect you were given (`draw_text` and `put` do it for you);
- take a `Theme` rather than reaching for a global one;
- keep state in a struct the caller owns and pass it by reference;
- return a `bool` from your `_key` function: true when you consumed the event;
- never call `tui::present` or `write` — the loop does that.

## 10. Goose habits that matter here

These cost real debugging time if you meet them in the order the compiler
reports them.

**A shift computes at the left operand's width.** `let b: u8 = 0xE4; b << 6` is
0. Widen first, or cast the value you shift:

```goose
let rr: u32 = r;
let colour = tui::COLOR_TRUECOLOR | (rr << 16) | (gg << 8) | bb;
```

**A resizable must be the last field** of a struct — transitively. If `State`
holds an `Input`, `Input` holds a `u8[>..]`, so `field: Input` goes last.

**A struct holds one resizable**, so build one buffer, not three. The framework
does this too: the front buffer and the output builder are locals of the loop,
not fields of anything.

**Slices are views; returning one into a by-value parameter is rejected.** Take
`T&` when you return a slice of it.

**Fixed arrays carry a length.** `u8[..76]` declared `[]` has length 0 and
cannot be indexed; use `.append(...)`, or `[0; 76]` when you want 76 zeros.

**A trailing block is an implicit last parameter.** Declare `fn f<F>(…)` and
call `f(x) { ev => … }`. When one trailing-block call wraps another, pass the
inner block at the call site.

**No UFCS across namespaces.** Inside `tui` you may write `st.bold()`; from your
own file write `tui::bold(st)`.

**`let` is immutable, and parameters are `let`.** Use `var` for anything you
assign. An untyped `var n = 0` is `i64`; annotate `i32` when the value feeds
rectangle math.
