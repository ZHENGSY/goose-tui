// tests/widgets.goose -- one golden screen per widget.
//
// A widget is a function over a rect, so its whole behaviour is the cells it
// leaves behind. These goldens are that: draw the widget on a small canvas and
// compare the text. Trailing spaces are trimmed, so a golden is a picture, not
// a byte count.
//
//   goose run tests/widgets.goose

import std;
import tui from "..";

var passed: i64 = 0;
var failed: i64 = 0;

fn check(name: const u8[:], ok: bool) {
    if ok { passed += 1; return; }
    failed += 1;
    print("FAIL  ", name);
}

// A key event, the way the decoder would build it.
fn ev_key(mods: u8, k: tui::Key) -> tui::Event {
    return tui::Event.Key { key: k, mods: mods };
}

fn main() {
    panels();
    lists();
    list_keys();
    tables();
    tabs();
    inputs();
    input_keys();
    gauges();
    sparks();
    scrollbars();
    paragraph();
    truncation();
    status_help();
    logs();
    focus();
    themes();
    print(passed, " passed, ", failed, " failed");
    if failed > 0 { exit(1); }
}

// --- harness ----------------------------------------------------------------

fn check_screen(name: const u8[:], cv: tui::Canvas&, want: const u8[:]) {
    let got = tui::screen_text(cv);
    if got == want { passed += 1; return; }
    failed += 1;
    print("FAIL  ", name);
    print("--- want ---");
    print(want);
    print("--- got ----");
    print(got);
    print("------------");
}

fn canvas(w: i32, h: i32) -> tui::Canvas {
    var c = tui::canvas(w, h);
    tui::canvas_clear(c, tui::th_text(tui::theme_dark()));
    return c;
}

// --- cases ------------------------------------------------------------------

fn panels() {
    var c = canvas(14, 4);
    let t = tui::theme_dark();
    let inner = tui::panel(c, tui::rect(0, 0, 14, 4), "hi", t);
    check("panel inner rect", inner.x == 1 && inner.y == 1 && inner.w == 12 && inner.h == 2);
    tui::text(c, inner, "body", tui::th_text(t));
    check_screen("panel", c,
            """
            ┌─ hi ───────┐
            │body        │
            │            │
            └────────────┘

            """);

    var f = canvas(8, 3);
    tui::panel_focus(f, tui::rect(0, 0, 8, 3), "", true, t);
    check_screen("panel focused", f,
            """
            ┌──────┐
            │      │
            └──────┘

            """);

    // a title too wide for the box is simply cut by the draw
    var n = canvas(9, 3);
    tui::panel(n, tui::rect(0, 0, 9, 3), "toolong", t);
    check_screen("panel narrow", n,
            """
            ┌─ toolo┐
            │       │
            └───────┘

            """);

    // too small for a border: the rect comes back untouched
    var s = canvas(1, 1);
    let back = tui::panel(s, tui::rect(0, 0, 1, 1), "x", t);
    check("panel degenerate", back.w == 1 && back.h == 1);
}

fn lists() {
    let t = tui::theme_dark();
    let items: const u8[:][3] = ["one", "two", "three"];
    var st = tui::list_state();
    var c = canvas(10, 3);
    tui::list(c, tui::rect(0, 0, 10, 3), st, items, t);
    check_screen("list first", c,
            """
             one
             two
             three

            """);

    st.sel = 2;
    var c2 = canvas(10, 3);
    tui::list(c2, tui::rect(0, 0, 10, 3), st, items, t);
    check_screen("list selection", c2,
            """
             one
             two
             three

            """);

    // more items than rows: the window follows the selection
    let many: const u8[:][6] = ["a", "b", "c", "d", "e", "f"];
    var st2 = tui::list_state();
    st2.sel = 5;
    var c3 = canvas(4, 2);
    tui::list(c3, tui::rect(0, 0, 4, 2), st2, many, t);
    check("list scrolls to selection", st2.top == 4);
    check_screen("list window", c3, " e\n f\n");

    // a selected row is padded to the full width of the list
    var st3 = tui::list_state();
    var c4 = canvas(6, 1);
    tui::list(c4, tui::rect(0, 0, 6, 1), st3, items, t);
    check_screen("list pads selection", c4, " one\n");
}

fn list_keys() {
    var st = tui::list_state();
    check("down moves", tui::list_key(st, ev_key(0, tui::Key.Down), 3) && st.sel == 1);
    check("up wraps", tui::list_key(st, ev_key(0, tui::Key.Up), 3) && st.sel == 0);
    check("up from zero wraps", tui::list_key(st, ev_key(0, tui::Key.Up), 3) && st.sel == 2);
    check("end", tui::list_key(st, ev_key(0, tui::Key.End), 3) && st.sel == 2);
    check("home", tui::list_key(st, ev_key(0, tui::Key.Home), 3) && st.sel == 0);
    check("page down wraps", tui::list_key(st, ev_key(0, tui::Key.PageDown), 3) && st.sel == 1);
    check("other key ignored", !tui::list_key(st, ev_key('x', tui::Key.Char { cp: 'x' }), 3));
    check("empty list ignored", !tui::list_key(st, ev_key(0, tui::Key.Down), 0));
}

fn tables() {
    let t = tui::theme_dark();
    let header: const u8[:][3] = ["name", "size", "kind"];
    let cells: const u8[:][6] = ["a.go", "120", "text", "b.png", "4k", "image"];
    let widths: const i32[3] = [7, 5, 0];
    var st = tui::table_state();
    var c = canvas(18, 4);
    tui::table(c, tui::rect(0, 0, 18, 4), st, header, cells, 3, widths, t);
    check_screen("table", c,
            """
             name   size kind
            ──────────────────
             a.go   120  text
             b.png  4k   image

            """);

    check("table cols tile", tui::table_cols(tui::rect(0, 0, 18, 1), widths, 3)[2].w == 6);

    // the header row is not selectable: selection starts in the body
    check("table selection", st.sel == 0 && st.top == 0);
    tui::table_key(st, ev_key(0, tui::Key.Down), 2);
    check("table down", st.sel == 1);
    tui::table_key(st, ev_key(0, tui::Key.Down), 2);
    check("table down wraps", st.sel == 0);
}

fn tabs() {
    let t = tui::theme_dark();
    let labels: const u8[:][3] = ["one", "two", "three"];
    var st = tui::tabs_state();
    var c = canvas(20, 1);
    tui::tabs(c, tui::rect(0, 0, 20, 1), st, labels, t);
    check_screen("tabs", c, "one  two  three\n");

    check("tabs_at hit", tui::tabs_at(tui::rect(0, 0, 20, 1), labels, 1) == 0);
    check("tabs_at second", tui::tabs_at(tui::rect(0, 0, 20, 1), labels, 7) == 1);
    check("tabs_at miss", tui::tabs_at(tui::rect(0, 0, 20, 1), labels, 19) == -1);

    check("tab key next", tui::tabs_key(st, ev_key(0, tui::Key.Tab), 3) && st.sel == 1);
    check("shift-tab back", tui::tabs_key(st, ev_key(tui::MOD_SHIFT, tui::Key.Tab), 3) && st.sel == 0);
    check("shift-tab wraps", tui::tabs_key(st, ev_key(tui::MOD_SHIFT, tui::Key.Tab), 3) && st.sel == 2);
    check("right wraps", tui::tabs_key(st, ev_key(0, tui::Key.Right), 3) && st.sel == 0);
}

fn inputs() {
    let t = tui::theme_dark();
    var st = tui::input_new();
    tui::input_set(st, "hello");
    var c = canvas(8, 1);
    let cur = tui::input(c, tui::rect(0, 0, 8, 1), st, true, t);
    check_screen("input", c, "hello\n");
    check("input caret", cur.visible && cur.x == 5 && cur.y == 0);

    // unfocused draws no caret
    var c2 = canvas(8, 1);
    let cur2 = tui::input(c2, tui::rect(0, 0, 8, 1), st, false, t);
    check("input unfocused caret hidden", !cur2.visible);

    // longer than the field: the window scrolls so the caret stays visible
    var long = tui::input_new();
    tui::input_set(long, "0123456789");
    var c3 = canvas(5, 1);
    let cur3 = tui::input(c3, tui::rect(0, 0, 5, 1), long, true, t);
    check_screen("input scrolled", c3, "6789\n");
    check("input scroll keeps caret inside", cur3.x <= 4 && cur3.x >= 0);
}

fn input_keys() {
    var st = tui::input_new();
    tui::input_key(st, ev_key(0, tui::Key.Char { cp: 'a' }));
    tui::input_key(st, ev_key(0, tui::Key.Char { cp: 'b' }));
    tui::input_key(st, ev_key(0, tui::Key.Char { cp: 'c' }));
    check("typing", st.text[..] == "abc" && st.cursor == 3);

    tui::input_key(st, ev_key(0, tui::Key.Left));
    tui::input_key(st, ev_key(0, tui::Key.Char { cp: 'X' }));
    check("insert mid-line", st.text[..] == "abXc" && st.cursor == 3);

    tui::input_key(st, ev_key(0, tui::Key.Backspace));
    check("backspace", st.text[..] == "abc" && st.cursor == 2);
    tui::input_key(st, ev_key(0, tui::Key.Delete));
    check("delete", st.text[..] == "ab" && st.cursor == 2);

    tui::input_key(st, ev_key(0, tui::Key.Home));
    check("home", st.cursor == 0);
    tui::input_key(st, ev_key(0, tui::Key.End));
    check("end", st.cursor == st.text.len);

    // ctrl-a is not text; it belongs to the application
    check("ctrl ignored", !tui::input_key(st, ev_key(tui::MOD_CTRL, tui::Key.Char { cp: 'a' })));
    check("arrow is consumed", tui::input_key(st, ev_key(0, tui::Key.Left)));

    // a multi-byte character is one caret step and one backspace
    var u = tui::input_new();
    tui::input_key(u, ev_key(0, tui::Key.Char { cp: 0x4E2D }));
    tui::input_key(u, ev_key(0, tui::Key.Char { cp: 'x' }));
    check("utf8 one caret step", u.cursor == 4 && u.text.len == 4);
    tui::input_key(u, ev_key(0, tui::Key.Left));
    check("utf8 left", u.cursor == 3);
    tui::input_key(u, ev_key(0, tui::Key.Backspace));
    check("utf8 backspace removes all three bytes", u.text[..] == "x" && u.cursor == 0);

    // backspace at zero does nothing, and says so
    var e = tui::input_new();
    check("backspace at start is a no-op", tui::input_key(e, ev_key(0, tui::Key.Backspace)) && e.text.len == 0);
}

fn gauges() {
    let t = tui::theme_dark();
    var c = canvas(10, 1);
    tui::gauge(c, tui::rect(0, 0, 10, 1), 0.5, "", t);
    check_screen("gauge half", c, "\n");

    var l = canvas(11, 1);
    tui::gauge(l, tui::rect(0, 0, 11, 1), 0.5, "50%", t);
    check_screen("gauge label over edge", l, "    50%\n");

    // out of range clamps rather than overflowing the rect
    var lo = canvas(4, 1);
    tui::gauge(lo, tui::rect(0, 0, 4, 1), -3.0, "", t);
    check_screen("gauge clamps low", lo, "\n");
    var hi = canvas(4, 1);
    tui::gauge(hi, tui::rect(0, 0, 4, 1), 9.0, "", t);
    check_screen("gauge clamps high", hi, "\n");
}

fn sparks() {
    let t = tui::theme_dark();
    let xs: const f64[4] = [0.0, 1.0, 2.0, 3.0];
    var c = canvas(4, 1);
    tui::spark(c, tui::rect(0, 0, 4, 1), xs, t);
    check_screen("spark ramp", c, "▁▃▅█\n");

    // a flat series is half height: nothing to scale against
    let flat: const f64[3] = [2.0, 2.0, 2.0];
    var f = canvas(3, 1);
    tui::spark(f, tui::rect(0, 0, 3, 1), flat, t);
    check_screen("spark flat", f, "▄▄▄\n");

    // more samples than columns: the newest win
    let many: const f64[6] = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0];
    var m = canvas(3, 1);
    tui::spark(m, tui::rect(0, 0, 3, 1), many, t);
    check_screen("spark trims from the left", m, "▅▆█\n");
}

fn scrollbars() {
    let t = tui::theme_dark();
    var c = canvas(1, 10);
    tui::scrollbar(c, tui::rect(0, 0, 1, 10), 0, 2, 20, t);
    let top = tui::screen_text(c);
    check("scrollbar thumb at top", top[..3] == "█" && top[top.len - 1] == '\n');

    var c2 = canvas(1, 10);
    tui::scrollbar(c2, tui::rect(0, 0, 1, 10), 18, 2, 20, t);
    let bottom = tui::screen_text(c2);
    check("scrollbar thumb at bottom", bottom[..3] == "│" && bottom[bottom.len - 4..bottom.len - 1] == "█");

    // nothing to scroll: nothing drawn
    var c3 = canvas(1, 4);
    tui::scrollbar(c3, tui::rect(0, 0, 1, 4), 0, 4, 4, t);
    check_screen("scrollbar hidden", c3, "\n\n\n\n");
}

fn paragraph() {
    let t = tui::theme_dark();
    var c = canvas(12, 4);
    let h = tui::para(c, tui::rect(0, 0, 12, 4), "the quick brown fox", tui::th_text(t));
    check("para returns rows used", h == 2);
    check_screen("para wraps", c,
            """
            the quick
            brown fox



            """);

    // a word longer than the line is broken, not dropped
    var c2 = canvas(5, 2);
    tui::para(c2, tui::rect(0, 0, 5, 2), "abcdefgh", tui::th_text(t));
    check_screen("para breaks long word", c2, "abcde\nfgh\n");

    // explicit newlines start new lines
    var c3 = canvas(6, 3);
    tui::para(c3, tui::rect(0, 0, 6, 3), "ab\ncd", tui::th_text(t));
    check_screen("para honours newlines", c3, "ab\ncd\n\n");
}

fn truncation() {
    let t = tui::theme_dark();
    var c = canvas(6, 1);
    tui::ellipsis(c, tui::rect(0, 0, 6, 1), 0, 0, "abcdefgh", tui::th_text(t));
    check_screen("ellipsis", c, "abcde…\n");

    var c2 = canvas(6, 1);
    tui::ellipsis(c2, tui::rect(0, 0, 6, 1), 0, 0, "abc", tui::th_text(t));
    check_screen("ellipsis leaves short text", c2, "abc\n");

    // wide glyphs: an ellipsis never splits a two-column glyph
    var c3 = canvas(5, 1);
    tui::ellipsis(c3, tui::rect(0, 0, 5, 1), 0, 0, "中中中", tui::th_text(t));
    check_screen("ellipsis wide", c3, "中中…\n");
}

fn status_help() {
    let t = tui::theme_dark();
    var c = canvas(20, 1);
    tui::status(c, tui::rect(0, 0, 20, 1), "ready", "1/9", t);
    check_screen("status", c, " ready          1/9\n");

    // the right half wins when they would collide
    var s = canvas(10, 1);
    tui::status(s, tui::rect(0, 0, 10, 1), "averylongleft", "right", t);
    check_screen("status collision", s, " averight\n");

    let keys_s: const u8[:][2] = ["q", "^S"];
    let descs: const u8[:][2] = ["quit", "save"];
    var h = canvas(20, 1);
    tui::help(h, tui::rect(0, 0, 20, 1), keys_s, descs, t);
    check_screen("help", h, "q quit  ^S save\n");
}

fn logs() {
    let t = tui::theme_dark();
    var c = canvas(8, 3);
    tui::log_view(c, tui::rect(0, 0, 8, 3), "a\nb\nc\nd", tui::th_text(t));
    check_screen("log_view keeps the tail", c, "b\nc\nd\n");

    // fewer lines than rows sit at the top
    var c2 = canvas(8, 3);
    tui::log_view(c2, tui::rect(0, 0, 8, 3), "only", tui::th_text(t));
    check_screen("log_view short", c2, "\n\nonly\n");
}

fn focus() {
    var f = tui::focus(3);
    check("focus starts at zero", tui::focused(f, 0) && !tui::focused(f, 1));
    tui::focus_next(f);
    check("focus_next", f.at == 1);
    tui::focus_prev(f);
    tui::focus_prev(f);
    check("focus_prev wraps", f.at == 2);
    check("focus_key tab", tui::focus_key(f, ev_key(0, tui::Key.Tab)) && f.at == 0);
    check("focus_key shift-tab", tui::focus_key(f, ev_key(tui::MOD_SHIFT, tui::Key.Tab)) && f.at == 2);
    check("focus_key other", !tui::focus_key(f, ev_key(0, tui::Key.Down)));
}

fn themes() {
    let d = tui::theme_dark();
    let l = tui::theme_light();
    check("dark and light differ", d.bg != l.bg && d.fg != l.fg);
    check("panel bg is not the screen bg", d.panel_bg != d.bg);
    // a theme is copied, not shared: changing a copy leaves the original alone
    var mine = d;
    mine.accent = tui::rgb(1, 2, 3);
    check("theme is a value", d.accent != mine.accent);
}
