# goose-tui reference

Every public name, grouped by module. All of them live in `namespace tui`, so
they are called as `tui::name(...)` from your code — never as methods, because
uniform call syntax does not cross a namespace.

Sizes are in cells unless stated otherwise. `Rect` is `{x, y, w, h}` in cells;
Y grows downwards, so row 0 is the top.

The platform contract — the escape sequences a terminal must implement, which
hosts are supported, and what a Windows backend would need — is in
[`platforms.md`](platforms.md).

---

## tui — terminal, app, loop

### Types

```goose
struct Size  { rows: i32, cols: i32 }
struct Term  { on: bool, w: i32, h: i32, idle_ms: i32, sized: bool }
struct App   { running: bool, theme: Theme, quit_on_ctrl_c: bool,
               cursor: Cursor, now_ms: i64, frames: i64 }
struct Cursor { visible: bool, x: i32, y: i32 }
```

### Terminal

| function | meaning |
|---|---|
| `term() -> Term` | a terminal at 80×24, not yet open, idle timeout 50 ms |
| `open(t) -> bool` | raw mode, alternate screen, hidden cursor, no autowrap. False if stdout is not a terminal |
| `close(t)` | leave the alternate screen, restore the mode and cursor. Idempotent |
| `set_mouse(t, on)` | enable/disable SGR mouse reporting. Off by default |
| `sync_size(t) -> bool` | re-read the window size; true when it changed (or on the first call) |
| `poll(t, buf) -> i32` | one read with `t.idle_ms` timeout: bytes read, 0 on timeout, <0 at end of input |
| `write_out(t, s)` | write raw bytes (one `write(2)`); bypasses the diff |
| `clock_ms() -> i64` | monotonic milliseconds |

### Application and loop

| function | meaning |
|---|---|
| `app() -> App` | running, dark theme, ctrl-C quits, cursor hidden |
| `quit(a)` | leave the loop after this frame |
| `set_cursor(a, cur)` | where the hardware cursor goes this frame |
| `hide_cursor(a)` | hide it this frame (also the default: every frame starts hidden) |
| `begin_frame(a, c)` | clear the canvas to the theme background and hide the caret. `run` calls it; call it yourself in a custom loop |
| `run(a, t, c) { cv, ev => … }` | the loop: resize, input, idle tick, present |
| `headless(a, c, input, ticks) { cv, ev => … }` | replay bytes and idle frames without a terminal |

`run` calls your block at least once per frame, and once per event when events
arrived. Only the last call's drawing is presented. `Event.None` means "a frame
with nothing to report": that is where animations advance.

`headless` feeds `input` as if typed (bracketed paste, arrows and all), then
`ticks` idle frames with the clock advancing 16 ms each, and leaves the result
in `c`. Nothing is written anywhere.

---

## rect — rectangle arithmetic

| function | meaning |
|---|---|
| `rect(x, y, w, h) -> Rect` | a rectangle |
| `right(r)`, `bottom(r)` | the far edges (x + w, y + h) |
| `is_empty(r)`, `area(r)` | zero-size test, w × h |
| `contains(r, x, y)` | point-in-rect |
| `inset(r, n)`, `inset_xy(r, dx, dy)` | shrink by n on each side (clamped at zero) |
| `clip(r, outer) -> Rect` | the intersection |
| `split_h(r, left) -> Rect, Rect` | split at a column; `left` is clamped to `0..r.w` |
| `split_v(r, top) -> Rect, Rect` | split at a row |
| `split_hw(r, num, den) -> Rect, Rect` | split at `w * num / den` |
| `split_vh(r, num, den) -> Rect, Rect` | the vertical form |
| `row_at(r, i, n) -> Rect` | row `i` of `n` equal rows (last takes the remainder) |
| `col_at(r, i, n) -> Rect` | column `i` of `n` |
| `center(r, w, h) -> Rect` | a `w`×`h` box centred in `r`, clamped |
| `clamp_i32(v, lo, hi)`, `clamp_i64(v, lo, hi)` | clamp |
| `wrap_i64(v, n)` | wrap into `0..n-1` (menu movement) |

---

## cell — style, canvas, drawing, presenter

### Style

```goose
struct Style { fg: u32, bg: u32, attr: u16 }
```

| function | meaning |
|---|---|
| `style(fg)`, `style(fg, bg)`, `style(fg, bg, attr)` | build a style; `bg` defaults to `COLOR_DEFAULT` |
| `rgb(r, g, b) -> u32` | a 24-bit colour |
| `ansi(n) -> u32` | a 256-colour index (0–15 are the base colours) |
| `COLOR_DEFAULT` | the terminal's own foreground/background |
| `is_truecolor(c) -> bool` | true for `rgb` colours, false for `COLOR_DEFAULT` |
| `with_attr(s, bits)`, `without_attr(s, bits)` | set/clear attribute bits |
| `bold`, `dim`, `italic`, `underline`, `reverse`, `strike` | `(s) -> Style` shorthands (also `.bold()` inside the package) |
| `ATTR_BOLD`, `ATTR_DIM`, `ATTR_ITALIC`, `ATTR_UNDERLINE`, `ATTR_BLINK`, `ATTR_REVERSE`, `ATTR_STRIKE` | attribute bits |
| `style_eq(a, b) -> bool` | structural equality |

### Canvas

```goose
struct Cell   { ch: u32, fg: u32, bg: u32, attr: u16, flags: u8 }
struct Canvas { w: i32, h: i32, cells: Cell[>..] }     // cells.len == w * h
```

`cells[y * w + x]` is the cell at `(x, y)`. `flags` is `CELL_NORMAL`,
`CELL_WIDE` (a two-column glyph's head) or `CELL_TAIL` (its second column).

| function | meaning |
|---|---|
| `canvas(w, h) -> Canvas` | a canvas of blanks in the default style |
| `canvas_resize(c, w, h)` | resize to w×h; cells are not re-flowed, so redraw the frame afterwards (`run` invalidates the front buffer for you) |
| `canvas_clear(c, s)` | fill every cell with a space in style `s` |
| `cell_at(c, x, y) -> Cell` | bounds-checked read (blank when outside) |
| `put(c, x, y, cp, s)` | one code point, width from the Unicode table |
| `put_ascii(c, x, y, b, s)` | one byte, no width lookup |
| `fill_rect(c, r, cp, s)` | fill a rect with a code point |
| `draw_text(c, r, x, y, s, st) -> i32` | one line, clipped to `r`; returns the column after the last glyph |
| `draw_text_right(c, r, y, s, st) -> i32` | right-aligned inside `r` |
| `draw_text_center(c, r, y, s, st) -> i32` | centred inside `r` |
| `draw_text_skip(c, r, x, y, s, skip, st)` | draw `s` starting `skip` columns in (used for labels over a gauge's edge) |
| `text_width(s) -> i32` | display columns: wide glyphs 2, combining marks 0 |
| `screen_text(c) -> u8[>..]` | the canvas as plain text, one `\n` per row, trailing blanks trimmed |
| `screen_debug(c) -> u8[>..]` | the same, plus an attribute trace per row |

### Presenter

```goose
present(out, c, front, want, shown) -> i32
invalidate(front)
cursor(x, y) -> Cursor
cursor_hidden() -> Cursor
```

`present` appends this frame's escape sequences to `out`, updates `front` to
what the terminal now shows, moves the hardware cursor to `want` (tracking the
last position in `shown`), and returns how many cells it wrote.

- unchanged cells cost nothing: an idle frame with a still caret appends 0 bytes;
- `CUP` is emitted only when the next changed cell is not where the cursor
  already is; `SGR` only when the style changes;
- a wide glyph writes its head and remembers both cells; overwriting either
  half repairs the pair;
- `invalidate(front)` forces a full repaint (after a resize, or on startup).

---

## utf8 — decoding, walking, width

| function | meaning |
|---|---|
| `utf8_decode(s, i) -> u32, i64` | the code point at byte `i` and the index after it; invalid input yields `U+FFFD` and advances one byte |
| `utf8_len(b) -> i64` | bytes in the sequence a lead byte starts (1 for an invalid lead) |
| `next_cp(s, i)`, `prev_cp(s, i)` | the next/previous code-point boundary, clamped |
| `wcwidth(cp) -> i32` | 0 combining, 2 wide (CJK, Hangul, emoji), -1 control |
| `U_FFFD` | the replacement code point |

---

## keys — events

### Types

```goose
enum Key {
    Char { cp: u32 }, Enter, Tab, Backspace, Esc, Delete, Insert,
    Up, Down, Left, Right, Home, End, PageUp, PageDown,
    F { n: u8 }, Unknown,
}

enum Event {
    Key { key: Key, mods: u8 },
    Mouse { x: i32, y: i32, button: u8, kind: u8 },
    Paste { text: u8[..256], len: i32 },
    Resize { w: i32, h: i32 },
    None,
}

struct Mouse { x: i32, y: i32, button: u8, kind: u8 }
```

Modifiers: `MOD_SHIFT`, `MOD_ALT`, `MOD_CTRL` (bit flags).
Mouse kinds: `MOUSE_PRESS`, `MOUSE_RELEASE`, `MOUSE_DRAG`, `MOUSE_MOVE`,
`MOUSE_SCROLL_UP`, `MOUSE_SCROLL_DOWN`.

### The decoder

| function | meaning |
|---|---|
| `decoder() -> Decoder` | a decoder in the ground state |
| `feed(d, bytes, now_ms) { ev => … }` | decode bytes, reporting each completed event |
| `flush(d, now_ms) { ev => … }` | resolve a lone `ESC` (after 25 ms) or a truncated UTF-8 sequence |

The decoder is resumable: a sequence split across two reads decodes correctly.
It handles CSI and SS3 arrows, `ESC [ 1 ; 5 A` modifiers, `CSI u`, `~`-style
keys (home/end/insert/delete/pgup/pgdn/F1–F12), SGR mouse, bracketed paste
(chunked at 256 bytes) and UTF-8 input including Alt+char.

### Reading events

| function | meaning |
|---|---|
| `key_of(ev) -> Key` | the key, or `Key.Unknown` |
| `mods_of(ev) -> u8` | the modifier bits, or 0 |
| `key_char(ev) -> u32` | the code point of a character key, or 0 |
| `key_is(ev, ch) -> bool` | this character with no modifiers |
| `key_is_ctrl(ev, ch) -> bool` | this character with Ctrl |
| `key_is_any(ev, want) -> bool` | this named key (modifiers ignored) |
| `is_ctrl_c(ev) -> bool` | Ctrl-C |
| `is_none(ev)` | the idle frame event |
| `is_key(ev)`, `is_mouse(ev)`, `is_paste(ev)`, `is_resize(ev)` | event kind |
| `mouse_of(ev) -> Mouse` | the fields; `x = -1` for a non-mouse event, so a hit test misses |
| `mouse_is_press(ev) -> bool` | a press on a real point |
| `paste_append(ev, out) -> i32` | append a paste's bytes to your buffer; returns the count |

---

## theme

```goose
struct Theme {
    fg, bg, dim, accent, border, border_focus,
    sel_fg, sel_bg, title, ok, warn, err, panel_bg: u32,
}
```

| function | meaning |
|---|---|
| `theme_dark()`, `theme_light()`, `theme_mono()`, `theme_nord()` | the shipped themes |
| `th_text(t)`, `th_dim(t)`, `th_panel(t)` | body, secondary, panel-background styles |
| `th_selected(t)` | selection (reverse video) |
| `th_border(t)`, `th_border_focus(t)` | borders |
| `th_title(t)`, `th_key(t)` | bold headings and key hints |
| `th_ok(t)`, `th_warn(t)`, `th_err(t)` | status colours |

A theme is a plain value: copy it, change a field, pass it around. There is no
registry and no global current theme.

---

## widgets

### Text

| function | meaning |
|---|---|
| `text(c, r, s, st) -> i32` | one line at the top-left of `r`; returns 1 if it drew |
| `text_at(c, r, x, y, s, st) -> i32` | one line at an absolute position, clipped to `r` |
| `centered(c, r, s, st)` | one line centred in `r` (vertically too) |
| `ellipsis(c, r, x, y, s, st)` | one line, truncated with `…` at the rect's edge, never splitting a wide glyph |
| `para(c, r, s, st) -> i32` | word-wrapped paragraph; returns the rows used |
| `hr(c, r, y, st)`, `vr(c, r, x, st)` | horizontal/vertical rule |

### Panel

| function | meaning |
|---|---|
| `panel(c, r, title, t) -> Rect` | a single-line border with the title in the top edge; returns the inside |
| `panel_focus(c, r, title, focused, t) -> Rect` | the same, in the focus border colour |

A panel costs no row of its own: the title is drawn into the border.

### List

```goose
struct ListState { sel: i64, top: i64 }
list_state() -> ListState
list(c, r, st, items, t)          // items: const u8[:][:]
list_key(st, ev, n) -> bool       // up/down/home/end/page, wrapping
list_scroll(st, h, n)             // keep the selection inside h rows
```

The list draws the window `st.top..st.top + r.h` and pads the selected row to
the full width.

### Table

```goose
struct TableState { sel: i64, top: i64 }
table_state() -> TableState
table(c, r, st, header, cells, cols, widths, t)
table_key(st, ev, rows) -> bool
table_cols(r, widths, cols) -> Rect[..16]
```

`cells` is row-major (`rows * cols` slices). `widths[i] <= 0` makes column `i`
share what is left equally; the last column takes the rounding slack. The
header row is not selectable; `sel` counts body rows.

### Tabs

```goose
struct TabsState { sel: i64 }
tabs_state() -> TabsState
tabs(c, r, st, labels, t)          // labels: const u8[:][:]
tabs_key(st, ev, n) -> bool        // tab/shift-tab/left/right, wrapping
tabs_at(r, labels, x) -> i64       // the tab under a mouse column, or -1
```

### Input

```goose
struct Input { cursor: i64, scroll: i32, text: u8[>..] }
input_new() -> Input
input_set(st, s)
input(c, r, st, focused, t) -> Cursor
input_key(st, ev) -> bool
```

`input` draws the text and, when focused, returns the caret position; pass it
to `set_cursor`. The caret moves by code point, and the visible window scrolls
so the caret stays inside `r`. `input_key` handles left/right/home/end/
backspace/delete and character insertion, and ignores modified characters so
your shortcuts still work.

`Input` holds a resizable, so it must be the **last** field of any struct that
contains it.

### Gauges, sparks, scrollbars, logs

| function | meaning |
|---|---|
| `gauge(c, r, frac, label, t)` | a bar filled to `frac` (clamped 0..1); a label is drawn across the fill edge in both colour sets |
| `spark(c, r, xs, t)` | one block glyph per sample, oldest first, scaled to the series' own min..max; the newest samples win when there are more than columns |
| `scrollbar(c, r, top, visible, total, t)` | a vertical scrollbar in the last column of `r`; nothing is drawn when everything fits |
| `log_view(c, r, s, st)` | the last lines of a newline-separated block, aligned to the bottom of `r` |

### Status and help

| function | meaning |
|---|---|
| `status(c, r, left, right, t)` | a reverse-video bar: a message on the left, a hint on the right, never overlapping |
| `help(c, r, keys, descs, t)` | key hints: keys in the accent colour, descriptions dim |

### Focus

```goose
struct Focus { at: i32, n: i32 }
focus(n) -> Focus
focused(f, id) -> bool
focus_next(f), focus_prev(f)
focus_key(f, ev) -> bool
```

A ring of focusable widgets addressed by index. `focus_key` handles Tab and
Shift-Tab and returns whether it moved.
