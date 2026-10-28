// 03 -- layout: rectangles, not a solver.
//
// Every box on this screen is a `tui::Rect` produced by integer arithmetic:
// a horizontal split for the sidebar, a vertical split for the footer, equal
// rows inside the body, and one centred box. Resize the terminal and the
// numbers change; nothing else does.
//
//   goose run 03_layout.goose
//   1 2 3      sidebar 20% / 30% / 50%
//   c          a centred modal
//   q          quit

import std;
import tui from "..";
import ._harness;

struct State { sidebar: i32, modal: bool }

fn main() {
    var t = tui::term();
    var app = tui::app();
    var c = tui::canvas(80, 24);
    var st = State { sidebar: 30, modal: false };

    harness::play(app, t, c) { cv, ev =>
        if tui::key_is(ev, 'q') || tui::key_is_any(ev, tui::Key.Esc) { tui::quit(app); }
        if tui::key_is(ev, '1') { st.sidebar = 20; }
        if tui::key_is(ev, '2') { st.sidebar = 30; }
        if tui::key_is(ev, '3') { st.sidebar = 50; }
        if tui::key_is(ev, 'c') { st.modal = !st.modal; }
        draw(cv, app.theme, st);
    };
}

fn draw(c: tui::Canvas&, th: tui::Theme, st: State&) {
    // The screen, minus a footer row.
    let all = tui::rect(0, 0, c.w, c.h);
    let screen, footer = tui::split_v(all, c.h - 1);

    // A sidebar of st.sidebar percent, then the body.
    let side, body = tui::split_hw(screen, st.sidebar, 100);

    box(c, side, "sidebar", th);
    var info: u8[>..] = [];
    format(info, "x ", side.x, " y ", side.y, "\nw ", side.w, " h ", side.h);
    tui::para(c, tui::inset(side, 1), info[..], tui::th_dim(th));

    // The body: a header strip and two equal panes.
    let head, rest = tui::split_v(body, 3);
    box(c, head, "body", th);
    let left, right = tui::split_hw(rest, 1, 2);
    box(c, left, "pane a", th);
    box(c, right, "pane b", th);      // the remainder: no gap, no overlap

    // Each pane split into three equal rows, so the arithmetic is visible.
    var i: i32 = 0;
    while i < 3 {
        let row = tui::row_at(tui::inset(left, 1), i, 3);
        var label: u8[>..] = [];
        format(label, "row ", i, "  y ", row.y, "  h ", row.h);
        tui::draw_text(c, row, row.x + 1, row.y, label[..], tui::th_dim(th));
        i += 1;
    }

    let bars = tui::inset(right, 1);
    var j: i32 = 0;
    while j < 4 {
        let col = tui::col_at(bars, j, 4);
        tui::gauge(c, tui::rect(col.x, col.y, col.w, 1), (j + 1) as f64 / 4.0, "", th);
        j += 1;
    }
    tui::centered(c, tui::row_at(bars, 3, 4), "col_at(4) + gauge", tui::th_dim(th));

    tui::status(c, footer, "1 2 3 sidebar width    c modal    q quit", "layout", th);

    if st.modal {
        let m = tui::center(all, 34, 7);
        tui::fill_rect(c, m, ' ', tui::style(th.fg, th.bg));   //不打洞: cover what is under
        box(c, m, "centred", th);
        tui::centered(c, tui::row_at(tui::inset(m, 1), 2, 3), "center(34, 7)", tui::th_text(th));
    }
}

// A panel whose title carries the rectangle it was given: the whole demo is
// this one line of bookkeeping.
fn box(c: tui::Canvas&, r: tui::Rect, title: const u8[:], th: tui::Theme) {
    var t: u8[>..] = [];
    format(t, " ", title, " ", r.w, "x", r.h, " ");
    tui::panel(c, r, t[..], th);
}
