// 01 -- hello: the smallest complete goose-tui program.
//
// A terminal, an app, a canvas the size of the terminal, and two ways out. The
// block is called once per event and once per idle frame; it draws the whole
// screen every time, and the presenter works out what actually changed.
//
//   goose run 01_hello.goose
//   goose run 01_hello.goose -- --dump

import std;
import tui from "..";
import ._harness;

fn main() {
    var t = tui::term();
    var app = tui::app();
    var c = tui::canvas(40, 8);
    harness::play(app, t, c) { cv, ev =>
        if tui::key_is(ev, 'q') || tui::key_is_any(ev, tui::Key.Esc) {
            tui::quit(app);
        }
        draw(cv);
    };
}

// Everything the program shows, drawn from scratch. One function, called every
// frame: there is no widget tree to keep in sync with the state.
fn draw(c: tui::Canvas&) {
    let th = tui::theme_dark();
    let inner = tui::panel(c, tui::rect(0, 0, c.w, c.h), "hello", th);
    let mid = inner.y + inner.h / 2 - 1;
    tui::centered(c, tui::rect(inner.x, mid - 1, inner.w, 1), "Hello, terminal.", tui::bold(tui::th_text(th)));
    tui::centered(c, tui::rect(inner.x, mid + 1, inner.w, 1), "a cell grid, a diff, no widget tree", tui::th_dim(th));
    tui::draw_text(c, inner, inner.x + 1, inner.y + inner.h - 1, "q quits", tui::th_dim(th));
}
