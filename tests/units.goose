// tests/units.goose -- the arithmetic the framework rests on.
//
// No terminal, no timing: rectangles tile, cells hold width-2 glyphs, UTF-8
// walks by code point, colours pack into u32.
//
//   goose run tests/units.goose

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
    splits();
    rows_and_cols();
    boxes();
    cells();
    utf8();
    widths();
    colours();
    print(passed, " passed, ", failed, " failed");
    if failed > 0 { exit(1); }
}

fn splits() {
    let r = tui::rect(0, 0, 80, 24);
    let l, rt = tui::split_h(r, 30);
    check("split_h left width", l.w == 30);
    check("split_h right width", rt.w == 50);
    check("split_h tiles", l.w + rt.w == r.w && rt.x == 30);

    let t, b = tui::split_v(r, 5);
    check("split_v top", t.h == 5 && b.y == 5 && t.h + b.h == 24);

    let q, rest = tui::split_hw(r, 1, 4);
    check("split_hw quarter", q.w == 20 && rest.w == 60);

    // a split clamps instead of producing a negative rect
    let none, all = tui::split_h(r, -10);
    check("split_h clamps low", none.w == 0 && all.w == 80);
    let e, all2 = tui::split_h(r, 999);
    check("split_h clamps high", e.w == 80 && all2.w == 0);
    let d, _ = tui::split_hw(r, 1, 0);
    check("split_hw zero denominator", d.w == 0);
}

fn rows_and_cols() {
    let r = tui::rect(2, 3, 37, 11);
    var sum: i32 = 0;
    var y = r.y;
    var i: i32 = 0;
    var contiguous = true;
    while i < 5 {
        let row = tui::row_at(r, i, 5);
        if row.y != y { contiguous = false; }
        sum += row.h;
        y += row.h;
        i += 1;
    }
    check("row_at tiles the height", sum == r.h && contiguous);

    let c = tui::col_at(r, 1, 3);
    check("col_at width", c.w == 12 && c.h == 11);
    check("row_at out of range", tui::row_at(r, 5, 5).h == 0);
}

fn boxes() {
    let r = tui::rect(10, 10, 40, 20);
    let i = tui::inset(r, 2);
    check("inset", i.x == 12 && i.y == 12 && i.w == 36 && i.h == 16);

    let c = tui::center(r, 10, 4);
    check("center", c.w == 10 && c.h == 4 && c.x == 25 && c.y == 18);

    let big = tui::center(tui::rect(0, 0, 8, 4), 20, 10);
    check("center clamps", big.w == 8 && big.h == 4);

    check("contains", tui::contains(r, 10, 10) && !tui::contains(r, 50, 10));
    check("clip", tui::clip(tui::rect(30, 0, 30, 5), r).w == 20);
    check("wrap", tui::wrap_i64(-1, 5) == 4 && tui::wrap_i64(7, 5) == 2);
    check("clamp", tui::clamp_i32(9, 0, 4) == 4);
}

fn cells() {
    var c = tui::canvas(10, 3);
    let th = tui::theme_dark();
    let st = tui::th_text(th);

    tui::canvas_clear(c, st);
    tui::draw_text(c, tui::rect(0, 0, 10, 3), 1, 1, "hi", st);
    check("draw_text", tui::screen_text(c) == "\n hi\n\n");

    // a width-2 glyph claims two cells, and a later write repairs both halves
    tui::put(c, 0, 2, 0x4E2D, st);            // 中
    check("wide head", c.cells[20].flags == tui::CELL_WIDE);
    check("wide tail", c.cells[21].flags == tui::CELL_TAIL);
    check("wide text", tui::screen_text(c) == "\n hi\n中\n");

    tui::put(c, 1, 2, 0x41, st);              // 'A' over the tail
    check("tail repaired", c.cells[20].flags == tui::CELL_NORMAL);
    check("tail replaced", tui::screen_text(c) == "\n hi\n A\n");

    check("text_width ascii", tui::text_width("hello") == 5);
    check("text_width wide", tui::text_width("中文") == 4);
    check("text_width combining", tui::text_width("e\xCC\x81") == 1);

    // a line longer than the rect stops at its edge
    var d = tui::canvas(5, 1);
    tui::canvas_clear(d, st);
    tui::draw_text(d, tui::rect(0, 0, 5, 1), 0, 0, "abcdefgh", st);
    check("clip on draw", tui::screen_text(d) == "abcde\n");

    // a combining mark is dropped rather than drawn on its own
    tui::canvas_clear(d, st);
    tui::draw_text(d, tui::rect(0, 0, 5, 1), 0, 0, "e\xCC\x81x", st);
    check("combining dropped", tui::screen_text(d) == "ex\n");

    // control bytes never reach the terminal
    tui::canvas_clear(d, st);
    tui::draw_text(d, tui::rect(0, 0, 5, 1), 0, 0, "a\x1b[2Jb", st);
    check("control dropped", tui::screen_text(d) == "a[2Jb\n");
}

fn utf8() {
    let s = "a中b";
    let cp0, at0 = tui::utf8_decode(s, 0);
    let cp1, at1 = tui::utf8_decode(s, 1);
    let cp2, at2 = tui::utf8_decode(s, 4);
    check("decode ascii", cp0 == 97 && at0 == 1);
    check("decode wide", cp1 == 0x4E2D && at1 == 4);
    check("decode past wide", cp2 == 98 && at2 == 5);
    check("next_cp", tui::next_cp(s, 0) == 1 && tui::next_cp(s, 1) == 4);
    check("prev_cp", tui::prev_cp(s, 4) == 1 && tui::prev_cp(s, 1) == 0);
    check("prev_cp clamps", tui::prev_cp(s, 0) == 0);
    check("next_cp clamps", tui::next_cp(s, 5) == 5);

    // a truncated sequence is one replacement character, not a crash
    let bad = "a\xE4\xB8";
    let cp, at = tui::utf8_decode(bad, 1);
    check("truncated yields U+FFFD", cp == tui::U_FFFD && at == 2);
}

fn widths() {
    // Latin is one column, CJK two, a combining mark none, control none at all
    check("width ascii", tui::wcwidth('a') == 1);
    check("width cjk", tui::wcwidth(0x4E2D) == 2);
    check("width hangul", tui::wcwidth(0xAC00) == 2);
    check("width fullwidth", tui::wcwidth(0xFF21) == 2);
    check("width kana", tui::wcwidth(0x3042) == 2);
    check("width combining", tui::wcwidth(0x0301) == 0);
    check("width variation selector", tui::wcwidth(0xFE0F) == 0);
    check("width emoji", tui::wcwidth(0x1F642) == 2);
    check("width esc", tui::wcwidth(0x1B) == -1);
    check("width tab", tui::wcwidth('\t') == -1);
    check("width del", tui::wcwidth(0x7F) == -1);
    check("width c1", tui::wcwidth(0x9B) == -1);
    check("width nbsp is narrow", tui::wcwidth(0xA0) == 1);
    check("width accented latin", tui::wcwidth(0xE9) == 1);
}

fn colours() {
    check("rgb packs", tui::rgb(1, 2, 3) == 0x01010203);
    check("rgb is truecolor", tui::is_truecolor(tui::rgb(0, 0, 0)));
    check("ansi is not", !tui::is_truecolor(tui::ansi(200)));
    check("ansi index", tui::ansi(200) == 200);
    check("default", !tui::is_truecolor(tui::COLOR_DEFAULT));

    let s = tui::bold(tui::style(tui::rgb(1, 2, 3)));
    check("bold sets a bit", (s.attr & tui::ATTR_BOLD) != 0);
    check("without clears it", (tui::without_attr(s, tui::ATTR_BOLD).attr & tui::ATTR_BOLD) == 0);
}
