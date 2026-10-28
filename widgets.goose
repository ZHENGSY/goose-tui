// tui/widgets.goose -- widgets are functions that draw into a Rect.
//
// There is no widget object, no tree and no ownership: a widget is told where
// it goes and which style to use, draws, and returns what the caller needs
// (the inner rect of a panel, the rows a paragraph used, the caret of an
// input). Interactive widgets keep their state in a small struct the caller
// declares, and take events through a *_key function so the application
// decides what a key means.
//
// That split is the reason the framework has no lifetimes: nothing here holds
// a reference to anything after it returns.

namespace tui;

import std;
import cell;
import rect;
import theme;
import keys;

// --- lines and boxes --------------------------------------------------------

fn hr(c: Canvas&, r: Rect, y: i32, st: Style) {
    var x = r.x;
    while x < r.x + r.w { put(c, x, y, 0x2500, st); x += 1; }
}

fn vr(c: Canvas&, r: Rect, x: i32, st: Style) {
    var y = r.y;
    while y < r.y + r.h { put(c, x, y, 0x2502, st); y += 1; }
}

// A single-line box. The title is drawn into the top border, so a panel costs
// no row of its own. Returns the rect inside the border.
fn panel(c: Canvas&, r: Rect, title: const u8[:], t: Theme) -> Rect {
    return panel_focus(c, r, title, false, t);
}

fn panel_focus(c: Canvas&, r: Rect, title: const u8[:], focused: bool, t: Theme) -> Rect {
    if r.w < 2 || r.h < 2 { return r; }
    var st = th_border(t);
    if focused { st = th_border_focus(t); }
    let bg = style(t.fg, t.bg);

    put(c, r.x, r.y, 0x250C, st);
    put(c, r.x + r.w - 1, r.y, 0x2510, st);
    put(c, r.x, r.y + r.h - 1, 0x2514, st);
    put(c, r.x + r.w - 1, r.y + r.h - 1, 0x2518, st);
    var x = r.x + 1;
    while x < r.x + r.w - 1 {
        put(c, x, r.y, 0x2500, st);
        put(c, x, r.y + r.h - 1, 0x2500, st);
        x += 1;
    }
    var y = r.y + 1;
    while y < r.y + r.h - 1 {
        put(c, r.x, y, 0x2502, st);
        put(c, r.x + r.w - 1, y, 0x2502, st);
        y += 1;
    }

    let inner = inset(r, 1);
    if title.len > 0 && inner.w > 4 {
        // A space either side of the title, drawn over the border. The title
        // is clipped to the border, so a long one cannot eat the corner.
        draw_text(c, r, r.x + 2, r.y, " ", bg);
        draw_text(c, rect(r.x + 3, r.y, r.w - 4, 1), r.x + 3, r.y, title, th_title(t));
        let tw = text_width(title);
        var px = r.x + 3 + tw;
        if px < r.x + r.w - 1 { draw_text(c, r, px, r.y, " ", bg); }
    }
    return inner;
}

// --- text -------------------------------------------------------------------

fn text(c: Canvas&, r: Rect, s: const u8[:], st: Style) -> i32 {
    if r.h <= 0 { return 0; }
    draw_text(c, r, r.x, r.y, s, st);
    return 1;
}

fn text_at(c: Canvas&, r: Rect, x: i32, y: i32, s: const u8[:], st: Style) -> i32 {
    return draw_text(c, r, x, y, s, st);
}

fn centered(c: Canvas&, r: Rect, s: const u8[:], st: Style) {
    if r.h <= 0 { return; }
    draw_text_center(c, r, r.y + r.h / 2, s, st);
}

// Text truncated to the rect's width, ending in an ellipsis when it does not
// fit. Use it anywhere a long label would otherwise be cut mid-glyph.
fn ellipsis(c: Canvas&, r: Rect, x: i32, y: i32, s: const u8[:], st: Style) {
    if text_width(s) <= r.w - (x - r.x) {
        draw_text(c, r, x, y, s, st);
        return;
    }
    var budget = r.x + r.w - x - 1;
    if budget <= 0 { return; }
    var i: i64 = 0;
    var cx = x;
    while i < s.len {
        let cp, next = utf8_decode(s, i);
        var cw = wcwidth(cp as i32);
        if cw <= 0 { cw = 1; }
        if cx + cw > x + budget { break; }
        put_width(c, cx, y, cp, cw, st);
        cx += cw;
        i = next;
    }
    put(c, cx, y, 0x2026, st);
}

// Word-wrapped text. Breaks at spaces, and at the column when a single word is
// wider than the rect (which is also what makes CJK text wrap at all, since
// it has no spaces). Returns the number of rows used.
fn para(c: Canvas&, r: Rect, s: const u8[:], st: Style) -> i32 {
    if r.w <= 0 || r.h <= 0 { return 0; }
    var i: i64 = 0;
    var row: i32 = 0;
    while i < s.len && row < r.h {
        let y = r.y + row;
        // find the end of this line
        var j = next_break(s, i, r.w);
        draw_text(c, rect(r.x, y, r.w, 1), r.x, y, s[i..j], st);
        i = j;
        // skip the space or newline the line broke at
        while i < s.len && (s[i] == ' ' || s[i] == '\n' || s[i] == '\t') { i += 1; }
        row += 1;
    }
    return row;
}

// The byte index just past the last character that fits in `maxw` columns,
// preferring to break just before the last space.
fn next_break(s: const u8[:], start: i64, maxw: i32) -> i64 {
    var i = start;
    var x: i32 = 0;
    var last_space: i64 = -1;
    while i < s.len {
        let cp, next = utf8_decode(s, i);
        if cp == '\n' { return i; }
        var cw = wcwidth(cp as i32);
        if cw < 0 { i = next; continue; }
        if cp == ' ' { last_space = i; }
        if x + cw > maxw {
            if last_space > start { return last_space; }
            if i == start { return next; }        // one glyph wider than the row
            return i;
        }
        x += cw;
        i = next;
    }
    return s.len;
}

// --- list -------------------------------------------------------------------

// Selection and scroll position: two numbers. Scroll is kept in "first visible
// row" form so a resize cannot scroll past the end.
struct ListState { sel: i64, top: i64 }

fn list_state() -> ListState { return ListState { sel: 0, top: 0 }; }

fn list_scroll(st: ListState&, h: i32, n: i64) {
    if n <= 0 { st.sel = 0; st.top = 0; return; }
    if st.sel >= n { st.sel = n - 1; }
    if st.sel < 0 { st.sel = 0; }
    if h <= 0 { st.top = 0; return; }
    if st.sel < st.top { st.top = st.sel; }
    if st.sel >= st.top + h { st.top = st.sel - h + 1; }
    if st.top > n - h { st.top = n - h; }
    if st.top < 0 { st.top = 0; }
}

fn list(c: Canvas&, r: Rect, st: ListState&, items: const u8[:][:], t: Theme) {
    list_scroll(st, r.h, items.len);
    var row: i32 = 0;
    while row < r.h {
        let idx = st.top + row;
        if idx >= items.len { break; }
        let y = r.y + row;
        if idx == st.sel {
            fill_rect(c, rect(r.x, y, r.w, 1), ' ', th_selected(t));
            draw_text(c, rect(r.x + 1, y, r.w - 1, 1), r.x + 1, y, items[idx], th_selected(t));
        } else {
            draw_text(c, rect(r.x + 1, y, r.w - 1, 1), r.x + 1, y, items[idx], th_text(t));
        }
        row += 1;
    }
}

// Returns true if the event was a list key and the state changed. The
// selection wraps, which is what makes a menu feel finished.
fn list_key(st: ListState&, ev: Event, n: i64) -> bool {
    if n <= 0 { return false; }
    let k = key_of(ev);
    var moved = true;
    if k == Key.Down { st.sel += 1; }
    else if k == Key.Up { st.sel -= 1; }
    else if k == Key.Home { st.sel = 0; }
    else if k == Key.End { st.sel = n - 1; }
    else if k == Key.PageDown { st.sel += 10; }
    else if k == Key.PageUp { st.sel -= 10; }
    else { moved = false; }
    if moved { st.sel = wrap_i64(st.sel, n); }
    return moved;
}

// --- table ------------------------------------------------------------------

// A table is a header plus a row-major grid of cells. Column widths come from
// `widths`; a width of 0 or less shares what is left equally between the
// flexible columns.
struct TableState { sel: i64, top: i64 }

fn table_state() -> TableState { return TableState { sel: 0, top: 0 }; }

// The x offset and width of every column, in one array of at most 16.
fn table_cols(r: Rect, widths: const i32[:], cols: i32) -> Rect[..16] {
    var out: Rect[..16] = [rect(0, 0, 0, 0); 16];
    if cols <= 0 || cols > 16 { return out; }
    var fixed: i32 = 0;
    var flex: i32 = 0;
    var i: i32 = 0;
    while i < cols {
        let w = if i < widths.len as i32 { widths[i] } else { 0 };
        if w > 0 { fixed += w; } else { flex += 1; }
        i += 1;
    }
    var left = r.w - fixed;
    if left < 0 { left = 0; }
    let each = if flex > 0 { left / flex } else { 0 };
    var x = r.x;
    i = 0;
    while i < cols {
        let w0 = if i < widths.len as i32 { widths[i] } else { 0 };
        var w = w0;
        if w <= 0 {
            w = each;
            if i == cols - 1 { w = r.x + r.w - x; }   // last column takes the slack
        }
        out[i] = rect(x, r.y, w, r.h);
        x += w;
        i += 1;
    }
    return out;
}

fn table(c: Canvas&, r: Rect, st: TableState&, header: const u8[:][:],
         cells: const u8[:][:], cols: i32, widths: const i32[:], t: Theme) {
    if cols <= 0 || r.h <= 0 { return; }
    let colr = table_cols(r, widths, cols);
    let rows = cells.len / cols;

    var row: i32 = 0;
    if r.h >= 2 && header.len > 0 {
        var ci: i32 = 0;
        while ci < cols {
            let cr = colr[ci];
            draw_text(c, cr, cr.x + 1, r.y, if ci < header.len as i32 { header[ci] } else { "" }, th_title(t));
            ci += 1;
        }
        hr(c, r, r.y + 1, th_border(t));
        row = 2;
    }

    let body_h = r.h - row;
    var view = ListState { sel: st.sel, top: st.top };
    list_scroll(view, body_h, rows);
    st.sel = view.sel;
    st.top = view.top;

    while row < r.h {
        let idx = st.top + (row - (r.h - body_h));
        if idx >= rows { break; }
        let y = r.y + row;
        let sel = idx == st.sel;
        if sel { fill_rect(c, rect(r.x, y, r.w, 1), ' ', th_selected(t)); }
        var ci: i32 = 0;
        while ci < cols {
            let cr = colr[ci];
            let at = idx * cols + ci;
            var stc = if sel { th_selected(t) } else { th_text(t) };
            if at >= cells.len { ci += 1; continue; }
            ellipsis(c, rect(cr.x + 1, y, cr.w - 1, 1), cr.x + 1, y, cells[at], stc);
            ci += 1;
        }
        row += 1;
    }
}

fn table_key(st: TableState&, ev: Event, rows: i64) -> bool {
    var view = ListState { sel: st.sel, top: st.top };
    let used = list_key(view, ev, rows);
    st.sel = view.sel;
    st.top = view.top;
    return used;
}

// --- tabs -------------------------------------------------------------------

struct TabsState { sel: i64 }

fn tabs_state() -> TabsState { return TabsState { sel: 0 }; }

// A one-line tab strip, drawn from the state's selection. `tabs_at` maps a
// mouse column back to a tab index, so a click is one line in the caller.
fn tabs(c: Canvas&, r: Rect, st: TabsState&, labels: const u8[:][:], t: Theme) {
    if r.h <= 0 { return; }
    var x = r.x;
    var i: i64 = 0;
    while i < labels.len {
        let w = text_width(labels[i]);
        if x + w > r.x + r.w { break; }
        let active = i == st.sel;
        var stl = th_dim(t);
        if active {
            stl = th_selected(t);
            fill_rect(c, clip(rect(x - 1, r.y, w + 2, 1), r), ' ', stl);
        }
        draw_text(c, rect(x, r.y, w, 1), x, r.y, labels[i], stl);
        x += w + 2;
        i += 1;
    }
    // the baseline under the strip
    if r.h > 1 {
        var bx = r.x;
        while bx < r.x + r.w { put(c, bx, r.y + 1, 0x2500, th_border(t)); bx += 1; }
    }
}

// Which tab is under column `x`, or -1. Labels are laid out as `tabs` draws
// them: the label, then two columns of padding.
fn tabs_at(r: Rect, labels: const u8[:][:], x: i32) -> i64 {
    var cx = r.x;
    var i: i64 = 0;
    while i < labels.len {
        let w = text_width(labels[i]);
        if x >= cx - 1 && x < cx + w + 1 { return i; }
        cx += w + 2;
        i += 1;
    }
    return -1;
}

fn tabs_key(st: TabsState&, ev: Event, n: i64) -> bool {
    if n <= 0 { return false; }
    if key_is_any(ev, Key.Tab) {
        if (mods_of(ev) & MOD_SHIFT) != 0 { st.sel = wrap_i64(st.sel - 1, n); }
        else { st.sel = wrap_i64(st.sel + 1, n); }
        return true;
    }
    if key_is_any(ev, Key.Left) { st.sel = wrap_i64(st.sel - 1, n); return true; }
    if key_is_any(ev, Key.Right) { st.sel = wrap_i64(st.sel + 1, n); return true; }
    return false;
}

// --- single-line text input -------------------------------------------------

// The text is a growable the caller owns; the widget edits it in place.
// `scroll` is the first visible byte, kept so the caret stays on screen.
struct Input { cursor: i64, scroll: i32, text: u8[>..] }

fn input_new() -> Input { return Input { cursor: 0, scroll: 0, text: [] }; }

fn input_set(st: Input&, s: const u8[:]) {
    st.text.clear();
    st.text.append(s);
    st.cursor = st.text.len;
    st.scroll = 0;
}

// Draws the field. Returns the caret's screen position when focused.
fn input(c: Canvas&, r: Rect, st: Input&, focused: bool, t: Theme) -> Cursor {
    if r.h <= 0 { return cursor_hidden(); }
    var stl = th_text(t);
    if focused { stl = style(t.fg, t.panel_bg); }
    fill_rect(c, r, ' ', stl);

    // Keep the caret inside the visible window. The scroll is a byte offset,
    // which is exact enough because a byte never occupies more than a column.
    if st.cursor < 0 { st.cursor = 0; }
    if st.cursor > st.text.len { st.cursor = st.text.len; }
    if st.scroll < 0 { st.scroll = 0; }
    if st.scroll > st.cursor { st.scroll = st.cursor as i32; }
    if st.scroll > st.text.len { st.scroll = st.text.len as i32; }
    let inner = r.w - 1;
    var from: i64 = st.scroll;
    while from < st.cursor && text_width(st.text[from..]) > inner { from += 1; }
    st.scroll = from as i32;

    draw_text(c, r, r.x, r.y, st.text[from..], stl);
    if !focused { return cursor_hidden(); }
    let cx = r.x + text_width(st.text[from..st.cursor]);
    return cursor(cx, r.y);
}

// Returns true when the text or the caret changed.
fn input_key(st: Input&, ev: Event) -> bool {
    let k = key_of(ev);
    if k == Key.Left { if st.cursor > 0 { st.cursor = prev_cp(st.text[..], st.cursor); } return true; }
    if k == Key.Right { if st.cursor < st.text.len { st.cursor = next_cp(st.text[..], st.cursor); } return true; }
    if k == Key.Home { st.cursor = 0; return true; }
    if k == Key.End { st.cursor = st.text.len; return true; }
    if k == Key.Backspace {
        if st.cursor > 0 {
            let at = prev_cp(st.text[..], st.cursor);
            var i = st.cursor - 1;
            while i >= at { remove_byte(st.text, i); i -= 1; }
            st.cursor = at;
        }
        return true;
    }
    if k == Key.Delete {
        if st.cursor < st.text.len {
            let to = next_cp(st.text[..], st.cursor);
            var i = st.cursor;
            while i < to { remove_byte(st.text, i); i += 1; }
        }
        return true;
    }
    match k {
        Char ch => {
            let m = mods_of(ev);
            if (m & MOD_CTRL) != 0 || (m & MOD_ALT) != 0 { return false; }
            insert_char(st.text, st.cursor, ch.cp);
            st.cursor = next_cp(st.text[..], st.cursor);
            return true;
        },
        _ => {},
    }
    return false;
}

// Inserts one code point's UTF-8 bytes at byte offset `at`.
fn insert_char(s: u8[>..]&, at: i64, cp: u32) {
    var tmp: u8[>..] = [];
    push_utf8(tmp, cp);
    var i: i64 = 0;
    while i < tmp.len {
        insert_at(s, at + i, tmp[i]);
        i += 1;
    }
}

// Removes one byte, shifting the rest down. Editing works in bytes here
// because `input_key` only ever removes a whole code point, one byte at a
// time, from the inside out.
fn remove_byte(s: u8[>..]&, i: i64) {
    var j = i;
    while j + 1 < s.len { s[j] = s[j + 1]; j += 1; }
    s.pop();
}

// --- gauges, charts, scrollbars ---------------------------------------------

// A horizontal bar, `frac` of the rect filled, with an optional centred label.
// The label is drawn across the fill edge: the part over the fill uses the
// selection colours, the part over the track the dim ones, so it stays
// readable however far the bar has gone.
fn gauge(c: Canvas&, r: Rect, frac: f64, label: const u8[:], t: Theme) {
    if r.w <= 0 || r.h <= 0 { return; }
    var f = frac;
    if f < 0.0 { f = 0.0; }
    if f > 1.0 { f = 1.0; }
    let filled = (f * r.w) as i32;
    let on = style(t.sel_fg, t.sel_bg);
    let off = style(t.dim, t.bg);
    fill_rect(c, rect(r.x, r.y, filled, r.h), ' ', on);
    fill_rect(c, rect(r.x + filled, r.y, r.w - filled, r.h), ' ', off);
    if label.len > 0 {
        let lw = text_width(label);
        let lx = r.x + (r.w - lw) / 2;
        let edge = r.x + filled;
        if lx < edge {
            draw_text(c, rect(lx, r.y, edge - lx, 1), lx, r.y, label, on);
            draw_text_skip(c, rect(edge, r.y, r.x + r.w - edge, 1), edge, r.y, label, edge - lx, off);
        } else {
            draw_text(c, r, lx, r.y, label, off);
        }
    }
}

// A sparkline: one block glyph per sample, oldest first, height from 1/8 to
// 8/8 of the rect. Values are scaled to the series' own min..max; a flat
// series draws half height.
fn spark(c: Canvas&, r: Rect, xs: const f64[:], t: Theme) {
    if r.h <= 0 || r.w <= 0 || xs.len == 0 { return; }
    var lo = xs[0];
    var hi = xs[0];
    for v in xs {
        if v < lo { lo = v; }
        if v > hi { hi = v; }
    }
    let span = hi - lo;
    let blocks: u32[8] = [0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, 0x2588];
    var col: i32 = 0;
    // the newest samples win when the series is longer than the rect
    var start: i64 = 0;
    if xs.len > r.w { start = xs.len - r.w; }
    var i = start;
    let y = r.y + r.h - 1;
    while i < xs.len && col < r.w {
        var f: f64 = 0.5;
        if span > 0.0 { f = (xs[i] - lo) / span; }
        var level = (f * 7.0) as i32;
        if level < 0 { level = 0; }
        if level > 7 { level = 7; }
        put(c, r.x + col, y, blocks[level], style(t.accent, t.bg));
        col += 1;
        i += 1;
    }
}

// A vertical scrollbar in the last column of `r`. `top` is the first visible
// row and `visible`/`total` are row counts: the thumb's size and position are
// the ratio between them.
fn scrollbar(c: Canvas&, r: Rect, top: i64, visible: i64, total: i64, t: Theme) {
    if r.h <= 0 || r.w <= 0 || total <= visible { return; }
    let x = r.x + r.w - 1;
    var h = ((r.h * visible) / total) as i32;
    if h < 1 { h = 1; }
    if h > r.h { h = r.h; }
    let span = total - visible;
    var t0 = top;
    if t0 < 0 { t0 = 0; }
    if t0 > span { t0 = span; }
    let travel = (r.h - h) as i64;
    var y0: i32 = 0;
    if travel > 0 { y0 = ((travel * t0) / span) as i32; }

    let on = style(t.border_focus, t.bg);
    let off = style(t.border, t.bg);
    var y: i32 = 0;
    while y < r.h {
        let filled = y >= y0 && y < y0 + h;
        let ch: u32 = if filled { 0x2588 } else { 0x2502 };
        put(c, x, r.y + y, ch, if filled { on } else { off });
        y += 1;
    }
}

// --- logs -------------------------------------------------------------------

// The last lines of a newline-separated block, aligned to the bottom of `r`:
// a log pane. Lines that no longer fit scroll off the top, which is what makes
// an app that appends to one growable feel like a terminal.
fn log_view(c: Canvas&, r: Rect, s: const u8[:], st: Style) {
    if r.h <= 0 || r.w <= 0 || s.len == 0 { return; }
    var starts: i64[..128] = [0; 128];
    var n: i32 = 0;
    // Walk backwards from the end, collecting the start of each line in front.
    var i = s.len;
    if s[i - 1] == '\n' { i -= 1; }
    while i > 0 && n < 128 && n < r.h {
        var j = i;
        while j > 0 && s[j - 1] != '\n' { j -= 1; }
        var k = n;
        while k > 0 { starts[k] = starts[k - 1]; k -= 1; }
        starts[0] = j;
        n += 1;
        if j == 0 { break; }
        i = j - 1;
    }
    var row: i32 = 0;
    let y0 = r.y + r.h - n;
    while row < n {
        let from = starts[row];
        var to = from;
        while to < s.len && s[to] != '\n' { to += 1; }
        draw_text(c, rect(r.x, y0 + row, r.w, 1), r.x, y0 + row, s[from..to], st);
        row += 1;
    }
}

// --- status bar -------------------------------------------------------------

// A reverse-video bar: a left message and a right-aligned hint. The message
// is clipped to what the hint leaves, so the two never overwrite each other.
fn status(c: Canvas&, r: Rect, left: const u8[:], right_s: const u8[:], t: Theme) {
    if r.h <= 0 { return; }
    let st = th_selected(t);
    fill_rect(c, r, ' ', st);
    let rw = text_width(right_s);
    var room = r.w - 2 - rw;
    if room < 0 { room = 0; }
    draw_text(c, rect(r.x + 1, r.y, room, 1), r.x + 1, r.y, left, st);
    draw_text_right(c, rect(r.x, r.y, r.w - 1, 1), r.y, right_s, st);
}

// A help line of key hints: "q quit   ↑↓ move". Each key is drawn in the
// accent colour and its description dim, which is easier to scan than prose.
fn help(c: Canvas&, r: Rect, keys_s: const u8[:][:], descs: const u8[:][:], t: Theme) {
    if r.h <= 0 { return; }
    var x = r.x;
    var i: i64 = 0;
    let n = if keys_s.len < descs.len { keys_s.len } else { descs.len };
    while i < n {
        let kw = text_width(keys_s[i]);
        if x + kw + 1 >= r.x + r.w { break; }
        draw_text(c, r, x, r.y, keys_s[i], th_key(t));
        x += kw + 1;
        let dw = text_width(descs[i]);
        if x + dw + 2 < r.x + r.w {
            draw_text(c, r, x, r.y, descs[i], th_dim(t));
            x += dw + 2;
        } else {
            break;
        }
        i += 1;
    }
}

// --- focus ------------------------------------------------------------------

// A ring of focusable widgets, addressed by index. Tab and Shift-Tab move it;
// a widget asks `focused(f, 2)` to know whether to draw its focus ring.
struct Focus { at: i32, n: i32 }

fn focus(n: i32) -> Focus { return Focus { at: 0, n: n }; }

fn focused(f: Focus, id: i32) -> bool { return f.at == id; }

fn focus_next(f: Focus&) {
    if f.n <= 0 { return; }
    f.at = (f.at + 1) % f.n;
}

fn focus_prev(f: Focus&) {
    if f.n <= 0 { return; }
    f.at = (f.at - 1 + f.n) % f.n;
}

// Moves the ring if the event is Tab / Shift-Tab. Returns true if it did.
fn focus_key(f: Focus&, ev: Event) -> bool {
    if !key_is_any(ev, Key.Tab) { return false; }
    if (mods_of(ev) & MOD_SHIFT) != 0 { focus_prev(f); } else { focus_next(f); }
    return true;
}
