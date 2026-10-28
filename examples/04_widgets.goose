// 04 -- widgets: the shipped set, side by side.
//
// Tabs, a panel, a scrolling list with a scrollbar, a selectable table, a
// wrapped paragraph, gauges, a sparkline, a text field with a real caret, a
// status bar and a help line. Every one of them is a function over a `Rect`.
//
//   goose run 04_widgets.goose
//   up/down  move in the list        tab  focus the field
//   left/right  switch tabs          type  edit the field
//   q  quit

import std;
import tui from "..";
import ._harness;

let FILES: const u8[:][12] = [
    "Documents", "Downloads", "Music", "Pictures", "Videos", "Projects",
    "Notes", "Screenshots", "Archive", "Desktop", "Library", "tmp",
];

let TABS: const u8[:][3] = ["overview", "space", "activity"];

let HEADER: const u8[:][4] = ["name", "size", "modified", "kind"];

let SAMPLES: f64[40] = [
    3.0, 5.0, 4.0, 8.0, 7.0, 9.0, 12.0, 10.0, 7.0, 6.0,
    8.0, 11.0, 14.0, 13.0, 9.0, 7.0, 6.0, 9.0, 12.0, 15.0,
    13.0, 10.0, 8.0, 7.0, 9.0, 11.0, 14.0, 16.0, 12.0, 10.0,
    8.0, 6.0, 7.0, 10.0, 13.0, 11.0, 9.0, 8.0, 10.0, 12.0,
];

let ROWS: const u8[:][24] = [
    "report.pdf", "2.4 MB", "09:12", "document",
    "notes.md", "18 KB", "08:40", "text",
    "build.log", "912 KB", "yesterday", "log",
    "photo.jpg", "4.1 MB", "yesterday", "image",
    "song.mp3", "8.0 MB", "Monday", "audio",
    "archive.tar", "31 MB", "Monday", "archive",
];

// A struct that holds a growable keeps it in its last field; `field` holds the
// text buffer, so it is last here.
struct State {
    tabs: tui::TabsState,
    list: tui::ListState,
    table: tui::TableState,
    focus: tui::Focus,
    field: tui::Input,
}

fn main() {
    var t = tui::term();
    var app = tui::app();
    var c = tui::canvas(78, 24);

    var st = State {
        tabs: tui::tabs_state(),
        list: tui::list_state(),
        table: tui::table_state(),
        focus: tui::focus(2),
        field: tui::input_new(),
    };
    tui::input_set(st.field, "/home/you/");

    harness::play(app, t, c) { cv, ev =>
        if tui::key_is(ev, 'q') { tui::quit(app); }
        if tui::focus_key(st.focus, ev) {
            // tab moved the ring; nothing else reads the key
        } else if tui::focused(st.focus, 0) {
            tui::list_key(st.list, ev, FILES.len);
        } else if tui::focused(st.focus, 1) {
            tui::tabs_key(st.tabs, ev, TABS.len);
        } else {
            tui::input_key(st.field, ev);
        }
        draw(cv, app, st);
    };
}

fn draw(c: tui::Canvas&, app: tui::App&, st: State&) {
    let th = app.theme;
    let all = tui::rect(0, 0, c.w, c.h);
    let top, rest = tui::split_v(all, 2);          // tabs + their baseline
    let screen, footer = tui::split_v(rest, rest.h - 2);

    tui::tabs(c, top, st.tabs, TABS, th);

    let side, main = tui::split_hw(screen, 28, 100);
    let inner = tui::panel_focus(c, side, " files ", tui::focused(st.focus, 0), th);
    tui::list(c, inner, st.list, FILES, th);
    tui::scrollbar(c, inner, st.list.top, inner.h, FILES.len, th);

    let table_r, lower = tui::split_v(main, 9);
    let tinner = tui::panel_focus(c, table_r, " table ", tui::focused(st.focus, 2), th);
    tui::table(c, tinner, st.table, HEADER, ROWS, 4, [0, 9, 12, 0], th);

    let pinner = tui::panel_focus(c, lower, " details ", false, th);
    let text_r, bottom = tui::split_v(pinner, pinner.h - 5);
    tui::para(c, text_r, "Widgets draw into the rect they are given and return what the caller needs: a panel returns its interior, a paragraph the rows it used. Nothing is retained between frames.", tui::th_text(th));

    tui::gauge(c, tui::row_at(bottom, 0, 5), 0.62, " 62% of 512 GB ", th);
    tui::gauge(c, tui::row_at(bottom, 1, 5), 0.18, " cache ", th);

    let spark_r = tui::row_at(bottom, 2, 5);
    tui::spark(c, tui::rect(spark_r.x, spark_r.y, spark_r.w, 2), SAMPLES[..], th);

    let field_r = tui::row_at(bottom, 4, 5);
    tui::set_cursor(app, tui::input(c, field_r, st.field, tui::focused(st.focus, 1), th));

    tui::status(c, tui::row_at(footer, 0, 2), "04 -- widgets", "tab focus   q quit", th);
    let help_r = tui::row_at(footer, 1, 2);
    tui::help(c, help_r, ["up/down", "left/right", "tab"], ["move", "switch tabs", "focus"], th);
}
