// 07 -- themes and colour: four themes, one struct.
//
// A theme is a flat struct of colours, so switching one is an assignment: no
// registry, no reload, no inheritance. On the right, the 256 ANSI indices and
// a 24-bit ramp, which is what the cell encoder has to know about.
//
//   goose run 07_theme.goose
//   t  next theme      q  quit

import std;
import tui from "..";
import ._harness;

let NAMES: const u8[:][4] = ["dark", "light", "nord", "mono"];

struct State { theme: i32 }

fn main() {
    var t = tui::term();
    var app = tui::app();
    var c = tui::canvas(80, 24);
    var st = State { theme: 0 };

    harness::play(app, t, c) { cv, ev =>
        if tui::key_is(ev, 'q') { tui::quit(app); }
        if tui::key_is(ev, 't') {
            st.theme = (st.theme + 1) % 4;
            app.theme = theme_at(st.theme);
        }
        draw(cv, app, st);
    };
}

fn theme_at(i: i32) -> tui::Theme {
    if i == 1 { return tui::theme_light(); }
    if i == 2 { return tui::theme_nord(); }
    if i == 3 { return tui::theme_mono(); }
    return tui::theme_dark();
}

fn draw(c: tui::Canvas&, app: tui::App&, st: State&) {
    let th = app.theme;
    let all = tui::rect(0, 0, c.w, c.h);
    let body, footer = tui::split_v(all, c.h - 2);
    let left, right = tui::split_hw(body, 44, 100);

    let inner = tui::panel(c, left, " preview ", th);
    var title: u8[>..] = [];
    format(title, " theme: ", NAMES[st.theme], "  (t to change) ");
    tui::draw_text(c, inner, inner.x, inner.y, title[..], tui::bold(tui::th_title(th)));

    let l1 = tui::row_at(inner, 1, 9);
    tui::para(c, l1, "Selected rows, borders, dim text, warnings and errors all come from the same struct of u32 colours.", tui::th_text(th));
    let l2 = tui::row_at(inner, 3, 9);
    tui::draw_text(c, l2, l2.x, l2.y, "ok  everything fine", tui::th_ok(th));
    let l3 = tui::row_at(inner, 4, 9);
    tui::draw_text(c, l3, l3.x, l3.y, "warn  almost out of space", tui::th_warn(th));
    let l4 = tui::row_at(inner, 5, 9);
    tui::draw_text(c, l4, l4.x, l4.y, "error  disk is full", tui::th_err(th));
    let l5 = tui::row_at(inner, 6, 9);
    tui::gauge(c, l5, 0.73, " 73% ", th);
    let l6 = tui::row_at(inner, 7, 9);
    tui::help(c, l6, ["t", "q"], ["next theme", "quit"], th);

    draw_palette(c, right, th);
    tui::status(c, tui::row_at(footer, 0, 2), "07 -- themes", NAMES[st.theme], th);
    tui::help(c, tui::row_at(footer, 1, 2), ["t"], ["cycle dark / light / nord / mono"], th);
}

// The 16 base colours, the 216-colour cube, and a truecolor ramp: three forms
// of the same `u32` colour value, drawn with cells and `style`.
fn draw_palette(c: tui::Canvas&, r: tui::Rect, th: tui::Theme) {
    let inner = tui::panel(c, r, " colour ", th);
    var row: i32 = 0;
    while row < 8 && row < inner.h {
        var col: i32 = 0;
        while col < 16 {
            let x = inner.x + col * 2;
            if x + 1 >= inner.x + inner.w { break; }
            let n = ((row * 16 + col) as u8);
            tui::fill_rect(c, tui::rect(x, inner.y + row, 2, 1), ' ', tui::style(tui::ansi(n), tui::ansi(n)));
            col += 1;
        }
        row += 1;
    }
    // a 24-bit ramp under the index grid
    let bar = tui::rect(inner.x, inner.y + 9, inner.w, 1);
    var x = bar.x;
    while x < bar.x + bar.w {
        let t = (x - bar.x) as f64 / (bar.w as f64 - 1.0);
        let cr = (t * 255.0) as u8;
        tui::fill_rect(c, tui::rect(x, bar.y, 1, 1), ' ', tui::style(tui::COLOR_DEFAULT, tui::rgb(cr, 120, 200)));
        x += 1;
    }
    let note = tui::rect(inner.x, inner.y + 11, inner.w, 1);
    tui::draw_text(c, note, note.x, note.y, "ansi(n)  ·  rgb(r, g, b)", tui::th_dim(th));
}
