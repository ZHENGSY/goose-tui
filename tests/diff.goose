// tests/diff.goose -- what actually reaches the terminal.
//
// The presenter is the part of a TUI that is easy to get wrong and hard to
// see: a frame that writes too much flickers, one that writes too little
// leaves stale glyphs. These tests assert the bytes, which is the only
// honest measure.
//
//   goose run tests/diff.goose

import std;
import tui from "..";

var passed: i64 = 0;
var failed: i64 = 0;

fn check(name: const u8[:], ok: bool) {
    if ok { passed += 1; return; }
    failed += 1;
    print("FAIL  ", name);
}

fn main() {
    idle_frames();
    glyph_deltas();
    caret_only();
    style_runs();
    wide_glyphs();
    full_repaint();
    measured();
    print(passed, " passed, ", failed, " failed");
    if failed > 0 { exit(1); }
}

// --- harness ----------------------------------------------------------------

fn count(hay: const u8[:], needle: const u8[:]) -> i32 {
    if needle.len == 0 || hay.len < needle.len { return 0; }
    var n: i32 = 0;
    var i: i64 = 0;
    while i + needle.len <= hay.len {
        if hay[i..i + needle.len] == needle { n += 1; i += needle.len; }
        else { i += 1; }
    }
    return n;
}

fn blank(w: i32, h: i32) -> tui::Canvas {
    var c = tui::canvas(w, h);
    tui::canvas_clear(c, tui::th_text(tui::theme_dark()));
    return c;
}

// Presents once and returns the bytes written.
struct Frame { cells: i32, bytes: u8[>..] }

fn present(c: tui::Canvas&, front: tui::Cell[>..]&, want: tui::Cursor,
           shown: tui::Cursor&) -> Frame {
    var out: u8[>..] = [];
    let n = tui::present(out, c, front, want, shown);
    return Frame { cells: n, bytes: out };
}

// --- cases ------------------------------------------------------------------

fn idle_frames() {
    var c = blank(20, 5);
    var front: tui::Cell[>..] = [];
    var shown = tui::cursor_hidden();

    let first = present(c, front, tui::cursor_hidden(), shown);
    check("first frame paints", first.bytes.len > 0 && first.cells == 100);
    check("first frame is one style", count(first.bytes[..], "m") == 1 && count(first.bytes[..], "H") == 5);

    let second = present(c, front, tui::cursor_hidden(), shown);
    check("idle frame writes nothing", second.bytes.len == 0 && second.cells == 0);

    // a frame redrawn identically is still nothing: that is what the
    // immediate-mode loop relies on when it redraws every frame
    tui::canvas_clear(c, tui::th_text(tui::theme_dark()));
    let third = present(c, front, tui::cursor_hidden(), shown);
    check("repaint of the same picture writes nothing", third.bytes.len == 0);

    // an empty canvas is valid too
    var e = tui::canvas(0, 0);
    var f2: tui::Cell[>..] = [];
    let ef = present(e, f2, tui::cursor_hidden(), shown);
    check("empty canvas", ef.cells == 0 && f2.len == 0);
}

fn glyph_deltas() {
    var c = blank(20, 5);
    var front: tui::Cell[>..] = [];
    var shown = tui::cursor_hidden();
    let _ = present(c, front, tui::cursor_hidden(), shown);

    // Two adjacent glyphs changed in one frame: one CUP for both, because the
    // second cell is exactly where the first left the cursor.
    tui::put(c, 3, 2, 'x', tui::th_text(tui::theme_dark()));
    tui::put(c, 4, 2, 'y', tui::th_text(tui::theme_dark()));
    let f = present(c, front, tui::cursor_hidden(), shown);
    check("two glyphs are two cells", f.cells == 2);
    check("adjacent glyphs share one cup", count(f.bytes[..], "H") == 1);
    check("the cup is the first cell", count(f.bytes[..], "\x1b[3;4H") == 1);

    // a gap on the same row needs a new CUP
    tui::put(c, 10, 2, 'z', tui::th_text(tui::theme_dark()));
    let f2 = present(c, front, tui::cursor_hidden(), shown);
    check("gap needs a cup", count(f2.bytes[..], "\x1b[3;11H") == 1);

    // a row change needs one too, even at the same column
    tui::put(c, 10, 3, 'w', tui::th_text(tui::theme_dark()));
    let f3 = present(c, front, tui::cursor_hidden(), shown);
    check("row change needs a cup", count(f3.bytes[..], "\x1b[4;11H") == 1);

    // clearing a cell writes a space, not an erase-to-end: the presenter
    // never assumes what else is on the terminal's screen
    tui::put(c, 10, 3, ' ', tui::th_text(tui::theme_dark()));
    let f4 = present(c, front, tui::cursor_hidden(), shown);
    check("clearing writes a space", f4.bytes[f4.bytes.len - 1] == ' ' &&
                                     count(f4.bytes[..], "\x1b[4;11H") == 1);
}

fn caret_only() {
    var c = blank(20, 2);
    var front: tui::Cell[>..] = [];
    var shown = tui::cursor_hidden();
    let _ = present(c, front, tui::cursor_hidden(), shown);

    // showing the caret over unchanged cells is a cursor move and nothing else
    let f = present(c, front, tui::cursor(4, 1), shown);
    check("caret move writes no glyph", f.cells == 0);
    check("caret move is show + cup", f.bytes[..] == "\x1b[?25h\x1b[2;5H");

    // the same caret again is idle
    let f2 = present(c, front, tui::cursor(4, 1), shown);
    check("caret that stays put is silent", f2.bytes.len == 0);

    // moving it one column costs exactly one CUP
    let f3 = present(c, front, tui::cursor(5, 1), shown);
    check("caret slide", f3.bytes[..] == "\x1b[2;6H");

    // hiding it again is one sequence
    let f4 = present(c, front, tui::cursor_hidden(), shown);
    check("caret hide", f4.bytes[..] == "\x1b[?25l");
    let f5 = present(c, front, tui::cursor_hidden(), shown);
    check("caret hide is not repeated", f5.bytes.len == 0);
}

fn style_runs() {
    let t = tui::theme_dark();
    var c = blank(6, 1);
    var front: tui::Cell[>..] = [];
    var shown = tui::cursor_hidden();

    // two colours on one row: one SGR per run, not per cell
    tui::draw_text(c, tui::rect(0, 0, 3, 1), 0, 0, "abc", tui::th_dim(t));
    tui::draw_text(c, tui::rect(3, 0, 3, 1), 3, 0, "def", tui::th_text(t));
    let f = present(c, front, tui::cursor_hidden(), shown);
    check("two runs, two SGRs", count(f.bytes[..], "m") == 2);
    check("two runs, one CUP", count(f.bytes[..], "H") == 1);
    check("all six glyphs", f.cells == 6);

    // a truecolour style carries its components
    var d = blank(1, 1);
    var f2: tui::Cell[>..] = [];
    tui::put(d, 0, 0, '#', tui::style(tui::rgb(1, 2, 3)));
    let fd = present(d, f2, tui::cursor_hidden(), shown);
    check("truecolor SGR", count(fd.bytes[..], ";2;1;2;3") == 1);

    // an ANSI index stays an index
    var a = blank(1, 1);
    var f3: tui::Cell[>..] = [];
    tui::put(a, 0, 0, '#', tui::style(tui::ansi(200)));
    let fa = present(a, f3, tui::cursor_hidden(), shown);
    check("ansi SGR", count(fa.bytes[..], ";5;200") == 1);

    // attributes travel with the colour they were attached to
    var b = blank(2, 1);
    var f4: tui::Cell[>..] = [];
    tui::put(b, 0, 0, 'B', tui::bold(tui::style(tui::ansi(1))));
    tui::put(b, 1, 0, 'C', tui::style(tui::ansi(1)));
    let fb = present(b, f4, tui::cursor_hidden(), shown);
    check("attribute change is a new SGR", count(fb.bytes[..], "m") == 2);
    check("bold is parameter 1", count(fb.bytes[..], "\x1b[0;1;") == 1);
}

fn wide_glyphs() {
    var c = blank(6, 1);
    var front: tui::Cell[>..] = [];
    var shown = tui::cursor_hidden();
    let _ = present(c, front, tui::cursor_hidden(), shown);

    tui::put(c, 1, 0, 0x4E2D, tui::th_text(tui::theme_dark()));   // 中, two columns
    let f = present(c, front, tui::cursor_hidden(), shown);
    check("wide glyph is one cell", f.cells == 1);
    check("wide glyph writes its head only", count(f.bytes[..], "中") == 1);
    check("wide tail is remembered", front[2].flags == tui::CELL_TAIL);

    // writing a glyph over the tail repairs the head
    tui::put(c, 2, 0, 'x', tui::th_text(tui::theme_dark()));
    let f2 = present(c, front, tui::cursor_hidden(), shown);
    check("head repaired", f2.cells == 2);            // space over the head, then x
    check("tail gone from the terminal", count(f2.bytes[..], "中") == 0);
}

fn full_repaint() {
    var c = blank(10, 3);
    var front: tui::Cell[>..] = [];
    var shown = tui::cursor_hidden();
    let _ = present(c, front, tui::cursor_hidden(), shown);

    tui::invalidate(front);
    let f = present(c, front, tui::cursor_hidden(), shown);
    check("invalidate repaints every cell", f.cells == 30);
    check("invalidate still one CUP per row", count(f.bytes[..], "H") == 3);

    // a front buffer of the wrong size is rebuilt, not trusted
    var c2 = blank(4, 2);
    var short_front: tui::Cell[>..] = [];
    short_front.push(tui::cell_invalid());
    let f2 = present(c2, short_front, tui::cursor_hidden(), shown);
    check("front buffer resized", short_front.len == 8 && f2.cells == 8);
}

// The numbers DESIGN.md quotes, measured rather than guessed. Printed so the
// document and the code cannot drift apart quietly.
fn measured() {
    let t = tui::theme_dark();
    var c = blank(80, 24);
    var front: tui::Cell[>..] = [];
    var shown = tui::cursor_hidden();

    // a plausible screen: a panel, a list and a status bar
    let inner = tui::panel(c, tui::rect(0, 0, 80, 22), "files", t);
    let items: const u8[:][6] = ["one.go", "two.go", "three.go", "four.go", "five.go", "six.go"];
    var st = tui::list_state();
    tui::list(c, tui::rect(inner.x, inner.y, 30, 6), st, items, t);
    tui::para(c, tui::rect(32, inner.y, 46, 4), "the quick brown fox jumps over the lazy dog", tui::th_text(t));
    tui::status(c, tui::rect(0, 23, 80, 1), "ready", "1/6", t);

    let full = present(c, front, tui::cursor(0, 23), shown);

    // idle: nothing changed, caret still
    let idle = present(c, front, tui::cursor(0, 23), shown);

    // one keystroke: a character appears in the text pane
    tui::put(c, 32, inner.y + 1, '!', tui::th_dim(t));
    let key = present(c, front, tui::cursor(0, 23), shown);

    // the caret moves without any glyph changing
    let move = present(c, front, tui::cursor(1, 23), shown);

    print("full 80x24 frame: ", full.bytes.len, " bytes, ", full.cells, " cells");
    print("idle frame:       ", idle.bytes.len, " bytes");
    print("one glyph:        ", key.bytes.len, " bytes");
    print("caret move:       ", move.bytes.len, " bytes");

    check("a full frame is about the screen size", full.bytes.len > 80 * 24);
    check("idle is free", idle.bytes.len == 0);
    check("a keystroke is a handful of bytes", key.bytes.len < 64);
    check("the caret is cheaper than a glyph", move.bytes.len < key.bytes.len);
}
