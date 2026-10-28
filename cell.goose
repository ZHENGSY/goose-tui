// tui/cell.goose -- cells, styles, the canvas, and the diffing presenter.
//
// A terminal is a grid of cells; so is a Canvas. One flat `Cell[>..]` with
// `index = y * w + x` is the fastest layout Goose can express: contiguous,
// no indirection, one bounds check per access.
//
// The presenter compares a frame against the previously shown frame and
// emits only what changed. An idle frame is zero bytes.

namespace tui;

import std;

// --- attributes -------------------------------------------------------------

let ATTR_BOLD: u16 = 1;
let ATTR_DIM: u16 = 2;
let ATTR_ITALIC: u16 = 4;
let ATTR_UNDERLINE: u16 = 8;
let ATTR_BLINK: u16 = 16;
let ATTR_REVERSE: u16 = 32;
let ATTR_STRIKE: u16 = 64;

// --- colours ----------------------------------------------------------------
//
// A colour is a u32 in one of three forms, told apart by bit 24:
//   0xFFFFFFFF            the terminal's default fg/bg
//   0x000000 .. 0x0000FF  an ANSI index (0-7 standard, 8-15 bright, 16-255)
//   0x01RRGGBB            a 24-bit colour
//
// The encoder below degrades by itself: a terminal that ignores `38;2;...`
// still draws the glyph, and `rgb` of one of the 16 base colours is written
// the same way on every terminal.

let COLOR_DEFAULT: u32 = 0xFFFFFFFF;
let COLOR_TRUECOLOR: u32 = 0x01000000;

// Widened before shifting: a shift computes at its left operand's width, so a
// u8 shifted by 16 would lose every bit it moved.
fn rgb(r: u8, g: u8, b: u8) -> u32 {
    let rr: u32 = r;
    let gg: u32 = g;
    let bb: u32 = b;
    return COLOR_TRUECOLOR | (rr << 16) | (gg << 8) | bb;
}

fn ansi(n: u8) -> u32 { return n; }

fn is_truecolor(c: u32) -> bool {
    return c != COLOR_DEFAULT && (c & COLOR_TRUECOLOR) != 0;
}

// --- style ------------------------------------------------------------------

struct Style { fg: u32, bg: u32, attr: u16 }

fn style(fg: u32) -> Style { return Style { fg: fg, bg: COLOR_DEFAULT, attr: 0 }; }
fn style(fg: u32, bg: u32) -> Style { return Style { fg: fg, bg: bg, attr: 0 }; }
fn style(fg: u32, bg: u32, attr: u16) -> Style { return Style { fg: fg, bg: bg, attr: attr }; }

fn with_attr(s: Style, attr: u16) -> Style {
    var t = s;
    t.attr = t.attr | attr;
    return t;
}

fn without_attr(s: Style, attr: u16) -> Style {
    var t = s;
    t.attr = t.attr & ~attr;
    return t;
}

fn bold(s: Style) -> Style { return with_attr(s, ATTR_BOLD); }
fn dim(s: Style) -> Style { return with_attr(s, ATTR_DIM); }
fn italic(s: Style) -> Style { return with_attr(s, ATTR_ITALIC); }
fn underline(s: Style) -> Style { return with_attr(s, ATTR_UNDERLINE); }
fn reverse(s: Style) -> Style { return with_attr(s, ATTR_REVERSE); }
fn strike(s: Style) -> Style { return with_attr(s, ATTR_STRIKE); }

fn style_eq(a: Style, b: Style) -> bool {
    return a.fg == b.fg && a.bg == b.bg && a.attr == b.attr;
}

// --- cells ------------------------------------------------------------------

// flags: 0 an ordinary cell, 1 the first column of a width-2 glyph,
// 2 the second column of one. The pair moves and compares as a unit.
let CELL_NORMAL: u8 = 0;
let CELL_WIDE: u8 = 1;
let CELL_TAIL: u8 = 2;

struct Cell { ch: u32, fg: u32, bg: u32, attr: u16, flags: u8 }

fn cell_blank() -> Cell {
    return Cell { ch: 32, fg: COLOR_DEFAULT, bg: COLOR_DEFAULT, attr: 0, flags: CELL_NORMAL };
}

fn cell_with(ch: u32, s: Style) -> Cell {
    return Cell { ch: ch, fg: s.fg, bg: s.bg, attr: s.attr, flags: CELL_NORMAL };
}

fn cell_eq(a: Cell, b: Cell) -> bool {
    return a.ch == b.ch && a.fg == b.fg && a.bg == b.bg && a.attr == b.attr && a.flags == b.flags;
}

// A cell no frame can produce, used to force a full redraw after a resize.
fn cell_invalid() -> Cell {
    return Cell { ch: 0x10FFFF, fg: COLOR_TRUECOLOR | 1, bg: COLOR_TRUECOLOR | 2, attr: 0xFFFF, flags: 3 };
}

// --- canvas -----------------------------------------------------------------

struct Canvas { w: i32, h: i32, cells: Cell[>..] }

fn canvas(w: i32, h: i32) -> Canvas {
    var c = Canvas { w: 0, h: 0, cells: [] };
    canvas_resize(c, w, h);
    return c;
}

fn canvas_resize(c: Canvas&, w: i32, h: i32) {
    var cw = w;
    var ch = h;
    if cw < 0 { cw = 0; }
    if ch < 0 { ch = 0; }
    c.w = cw;
    c.h = ch;
    c.cells.resize((cw * ch) as i64, cell_blank());
}

fn canvas_clear(c: Canvas&, s: Style) {
    let b = cell_with(32, s);
    for &cell in c.cells { cell = b; }
}

// Index in range, or -1. Every drawing primitive funnels through this, which
// is why no widget needs its own bounds check.
fn cell_index(c: Canvas&, x: i32, y: i32) -> i64 {
    if x < 0 || y < 0 || x >= c.w || y >= c.h { return -1; }
    return y * c.w + x;
}

fn cell_at(c: Canvas&, x: i32, y: i32) -> Cell {
    let i = cell_index(c, x, y);
    if i < 0 { return cell_blank(); }
    return c.cells[i];
}

// Writes one glyph of display width `wd` (1 or 2 columns). Repairing the
// neighbours is what keeps wide characters from corrupting the grid: a cell
// that was half of a wide glyph becomes a space, so its other half never
// claims a column it no longer owns.
fn put_width(c: Canvas&, x: i32, y: i32, ch: u32, wd: i32, s: Style) {
    let i = cell_index(c, x, y);
    if i < 0 { return; }
    if wd >= 2 && x + 1 >= c.w { return; }        // no room for the second column

    if c.cells[i].flags == CELL_TAIL && x > 0 {
        let j = cell_index(c, x - 1, y);
        if j >= 0 { c.cells[j] = cell_with(32, s); }
    }
    if c.cells[i].flags == CELL_WIDE {
        let j = cell_index(c, x + 1, y);
        if j >= 0 { c.cells[j] = cell_with(32, s); }
    }

    c.cells[i] = Cell { ch: ch, fg: s.fg, bg: s.bg, attr: s.attr,
                        flags: if wd >= 2 { CELL_WIDE } else { CELL_NORMAL } };
    if wd >= 2 {
        let j = cell_index(c, x + 1, y);
        if j >= 0 {
            c.cells[j] = Cell { ch: 0, fg: s.fg, bg: s.bg, attr: s.attr, flags: CELL_TAIL };
        }
    }
}

fn put(c: Canvas&, x: i32, y: i32, ch: u32, s: Style) {
    var wd = wcwidth(ch as i32);
    if wd <= 0 { wd = 1; }
    put_width(c, x, y, ch, wd, s);
}

fn put_ascii(c: Canvas&, x: i32, y: i32, b: u8, s: Style) {
    let i = cell_index(c, x, y);
    if i < 0 { return; }
    c.cells[i] = cell_with(b, s);
}

// How many columns `s` occupies when drawn, combining marks counted as zero.
fn text_width(s: const u8[:]) -> i32 {
    var w: i32 = 0;
    each_utf8(s) { cp =>
        var cw = wcwidth(cp as i32);
        if cw > 0 { w += cw; }
    };
    return w;
}

// Draws one line at (x, y), clipped to `r`. Returns the column after the last
// glyph drawn. Control characters are dropped rather than sent to the
// terminal: a stray ESC in a log line must not become an escape sequence.
fn draw_text(c: Canvas&, r: Rect, x: i32, y: i32, s: const u8[:], st: Style) -> i32 {
    var cx = x;
    if y < r.y || y >= r.y + r.h { return x; }
    let stop = r.x + r.w;
    if cx >= stop { return x; }
    var i: i64 = 0;
    while i < s.len {
        let cp, next = utf8_decode(s, i);
        i = next;
        var cw = wcwidth(cp as i32);
        if cw < 0 { continue; }                    // control: skip it
        if cw == 0 {
            // A combining mark would have to join the cell before it, but a
            // Cell holds one code point. Drop it: "e" + U+0301 draws as "e".
            continue;
        }
        if cx + cw > stop { return cx; }
        put_width(c, cx, y, cp, cw, st);
        cx += cw;
    }
    return cx;
}

// A centred one-line string inside `r`, truncated with an ellipsis if needed.
fn draw_text_center(c: Canvas&, r: Rect, y: i32, s: const u8[:], st: Style) -> i32 {
    let w = text_width(s);
    var x = r.x + (r.w - w) / 2;
    if x < r.x { x = r.x; }
    return draw_text(c, r, x, y, s, st);
}

// Draws `s` starting `skip` display columns into the string, at (x, y). The
// glyphs before `skip` are not drawn: this is how one string is drawn across a
// style boundary, such as the edge of a gauge's fill.
fn draw_text_skip(c: Canvas&, r: Rect, x: i32, y: i32, s: const u8[:], skip: i32, st: Style) {
    var i: i64 = 0;
    var col: i32 = 0;
    while i < s.len && col < skip {
        let cp, next = utf8_decode(s, i);
        var cw = wcwidth(cp as i32);
        if cw <= 0 { cw = 1; }
        col += cw;
        i = next;
    }
    draw_text(c, r, x, y, s[i..], st);
}

// A right-aligned one-line string inside `r`.
fn draw_text_right(c: Canvas&, r: Rect, y: i32, s: const u8[:], st: Style) -> i32 {
    let w = text_width(s);
    var x = r.x + r.w - w;
    if x < r.x { x = r.x; }
    return draw_text(c, r, x, y, s, st);
}

fn fill_rect(c: Canvas&, r: Rect, ch: u32, s: Style) {
    var y = r.y;
    let y1 = r.y + r.h;
    while y < y1 {
        var x = r.x;
        let x1 = r.x + r.w;
        while x < x1 { put(c, x, y, ch, s); x += 1; }
        y += 1;
    }
}

// --- escape sequences -------------------------------------------------------

fn emit_sgr(out: u8[>..]&, s: Style) {
    var p: u8[>..] = [];
    p.push('0');
    if (s.attr & ATTR_BOLD) != 0 { p.append(";1"); }
    if (s.attr & ATTR_DIM) != 0 { p.append(";2"); }
    if (s.attr & ATTR_ITALIC) != 0 { p.append(";3"); }
    if (s.attr & ATTR_UNDERLINE) != 0 { p.append(";4"); }
    if (s.attr & ATTR_BLINK) != 0 { p.append(";5"); }
    if (s.attr & ATTR_REVERSE) != 0 { p.append(";7"); }
    if (s.attr & ATTR_STRIKE) != 0 { p.append(";9"); }
    append_color(p, s.fg, 38, 39);
    append_color(p, s.bg, 48, 49);
    out.push('\x1b');
    out.push('[');
    out.append(p[..]);
    out.push('m');
}

// One colour as SGR parameters: `;39` for the default, `;38;5;n` for an ANSI
// index, `;38;2;r;g;b` for 24-bit. All of them go into the caller's parameter
// buffer so a style change is a single escape sequence.
fn append_color(p: u8[>..]&, col: u32, base: i32, fallback: i32) {
    if col == COLOR_DEFAULT {
        format(p, ";", fallback);
        return;
    }
    if is_truecolor(col) {
        format(p, ";", base, ";2;", (col >> 16) & 0xFF, ";", (col >> 8) & 0xFF, ";", col & 0xFF);
        return;
    }
    format(p, ";", base, ";5;", col);
}

fn emit_cup(out: u8[>..]&, x: i32, y: i32) {
    format(out, "\x1b[", y + 1, ";", x + 1, "H");
}

// --- the presenter ----------------------------------------------------------

struct Cursor { visible: bool, x: i32, y: i32 }

fn cursor(x: i32, y: i32) -> Cursor { return Cursor { visible: true, x: x, y: y }; }
fn cursor_hidden() -> Cursor { return Cursor { visible: false, x: 0, y: 0 }; }

fn invalidate(front: Cell[>..]&) {
    let bad = cell_invalid();
    for &cell in front { cell = bad; }
}

// Appends this frame's escape sequences to `out` and updates `front` to match
// what the terminal now shows. `shown` is the cursor the terminal is believed
// to be showing: the caret is moved even on a frame that changes no cell,
// which is what makes a caret slide over unchanged text. Returns the number of
// cells written.
fn present(out: u8[>..]&, c: Canvas&, front: Cell[>..]&, want: Cursor, shown: Cursor&) -> i32 {
    out.clear();
    let w = c.w;
    let h = c.h;
    if front.len != c.cells.len { front.resize(c.cells.len as i64, cell_invalid()); }

    var last_x: i32 = -1;
    var last_y: i32 = -1;
    var last_fg: u32 = 0;
    var last_bg: u32 = 0;
    var last_attr: u16 = 0;
    var have_style = false;
    var wrote: i32 = 0;

    var y: i32 = 0;
    while y < h {
        var x: i32 = 0;
        while x < w {
            let i = (y * w + x) as i64;
            let bc = c.cells[i];
            if bc.flags == CELL_TAIL { x += 1; continue; }
            if cell_eq(bc, front[i]) {
                // A wide head that still matches also guarantees its tail.
                if bc.flags == CELL_WIDE { x += 2; } else { x += 1; }
                continue;
            }
            var wd: i32 = 1;
            if bc.flags == CELL_WIDE { wd = 2; }
            if x != last_x || y != last_y {
                emit_cup(out, x, y);
            }
            if !have_style || bc.fg != last_fg || bc.bg != last_bg || bc.attr != last_attr {
                let st = Style { fg: bc.fg, bg: bc.bg, attr: bc.attr };
                emit_sgr(out, st);
                last_fg = bc.fg;
                last_bg = bc.bg;
                last_attr = bc.attr;
                have_style = true;
            }
            push_utf8(out, bc.ch);
            front[i] = bc;
            if wd == 2 && i + 1 < front.len { front[i + 1] = c.cells[i + 1]; }
            last_x = x + wd;
            last_y = y;
            wrote += 1;
            x += wd;
        }
        y += 1;
    }

    // The hardware cursor follows the frame, not the clock: an idle frame with
    // an unchanged caret writes nothing at all, so the caret does not flicker.
    // A frame that wrote cells has moved the terminal's cursor, so a visible
    // caret is put back where it belongs even when it did not move itself.
    let moved = want.visible != shown.visible || want.x != shown.x || want.y != shown.y;
    if moved || (out.len > 0 && want.visible) {
        if want.visible {
            if !shown.visible { out.append("\x1b[?25h"); }
            emit_cup(out, want.x, want.y);
        } else {
            out.append("\x1b[?25l");
        }
        shown = want;
    }
    return wrote;
}

// --- plain-text dump, for tests and for HEADLESS rendering -------------------

// The canvas as text: one line per row, wide glyphs once, trailing blanks
// trimmed. No escapes, so a test can compare it to a golden file.
fn screen_text(c: Canvas&) -> u8[>..] {
    var out: u8[>..] = [];
    var y: i32 = 0;
    while y < c.h {
        var line: u8[>..] = [];
        var x: i32 = 0;
        while x < c.w {
            let cell = c.cells[y * c.w + x];
            if cell.flags == CELL_TAIL { x += 1; continue; }
            push_utf8(line, cell.ch);
            x += 1;
        }
        var n = line.len;
        while n > 0 && line[n - 1] == ' ' { n -= 1; }
        out.append(line[..n]);
        out.push('\n');
        y += 1;
    }
    return out;
}

// The canvas as text with a style trace, for tests that care about colour:
// each row is followed by a line of the attribute nibbles that differ from
// the row's first cell. Compact enough to keep goldens readable.
fn screen_debug(c: Canvas&) -> u8[>..] {
    var out: u8[>..] = [];
    var y: i32 = 0;
    while y < c.h {
        var x: i32 = 0;
        var last = Cell { ch: 0, fg: 0, bg: 0, attr: 0, flags: 0 };
        var have = false;
        while x < c.w {
            let cell = c.cells[y * c.w + x];
            if cell.flags == CELL_TAIL { x += 1; continue; }
            if !have || cell.fg != last.fg || cell.bg != last.bg || cell.attr != last.attr {
                format(out, "{", cell.fg, ":", cell.bg, ":", cell.attr, "}");
                last = cell;
                have = true;
            }
            push_utf8(out, cell.ch);
            x += 1;
        }
        out.push('\n');
        y += 1;
    }
    return out;
}
