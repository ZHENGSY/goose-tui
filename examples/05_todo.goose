// 05 -- todo: an application, not a widget demo.
//
// A text field, a list you can tick off, and the state that ties them
// together: 64 fixed-size items, an index, and a growable the input widget
// edits. That is the whole program's data, on the stack, with no framework
// object owning it.
//
//   goose run 05_todo.goose
//   type + enter  add      space  toggle      x  delete
//   up/down       move     q      quit

import std;
import tui from "..";
import ._harness;

let MAX: i32 = 64;
let TEXT_MAX: i32 = 76;

struct Item { text: u8[..76], done: bool }

// `field` holds a growable, so it is the last field.
struct State {
    items: Item[..64],
    n: i32,
    list: tui::ListState,
    field: tui::Input,
}

fn main() {
    var t = tui::term();
    var app = tui::app();
    var c = tui::canvas(60, 20);

    var st = State {
        items: [Item { text: [], done: false }; 64],
        n: 0,
        list: tui::list_state(),
        field: tui::input_new(),
    };
    seed(st);

    harness::play(app, t, c) { cv, ev =>
        update(app, st, ev);
        draw(cv, app, st);
    };
}

fn seed(st: State&) {
    add(st, "read the goose spec");
    add(st, "write a tui in it");
    toggle(st, 0);
}

// --- keys -------------------------------------------------------------------

fn update(app: tui::App&, st: State&, ev: tui::Event) {
    if tui::key_is(ev, 'q') && st.field.text.len == 0 { tui::quit(app); return; }
    if tui::key_is_ctrl(ev, 'c') { tui::quit(app); return; }

    if tui::key_is_any(ev, tui::Key.Up) { move_sel(st, -1); return; }
    if tui::key_is_any(ev, tui::Key.Down) { move_sel(st, 1); return; }
    // while the field has text, every printable key is text: the list commands
    // take over once Enter has taken the line
    if st.field.text.len == 0 {
        if tui::key_is(ev, ' ') { toggle(st, st.list.sel); return; }
        if tui::key_is(ev, 'x') { remove_sel(st); return; }
    }

    if tui::key_is_any(ev, tui::Key.Enter) {
        if st.field.text.len > 0 {
            add(st, st.field.text[..]);
            st.field.text.clear();
            st.field.cursor = 0;
            st.field.scroll = 0;
            st.list.sel = st.n - 1;
        }
        return;
    }

    // a paste goes into the field, one line only
    if tui::is_paste(ev) {
        var text: u8[>..] = [];
        tui::paste_append(ev, text);
        var i: i64 = 0;
        while i < text.len {
            if text[i] == '\n' || text[i] == '\r' { break; }
            tui::insert_char(st.field.text, st.field.cursor, text[i]);
            st.field.cursor = tui::next_cp(st.field.text[..], st.field.cursor);
            i += 1;
        }
        return;
    }

    tui::input_key(st.field, ev);
}

fn move_sel(st: State&, d: i64) {
    if st.n == 0 { return; }
    st.list.sel = tui::wrap_i64(st.list.sel + d, st.n);
}

fn toggle(st: State&, i: i64) {
    if i < 0 || i >= st.n { return; }
    st.items[i].done = !st.items[i].done;
}

fn remove_sel(st: State&) {
    if st.n == 0 { return; }
    let at = st.list.sel as i32;
    var i = at;
    while i + 1 < st.n { st.items[i] = st.items[i + 1]; i += 1; }
    st.n -= 1;
    st.list.top = 0;
    if st.list.sel >= st.n { st.list.sel = st.n - 1; }
    if st.list.sel < 0 { st.list.sel = 0; }
}

fn add(st: State&, text: const u8[:]) {
    if st.n >= MAX || text.len == 0 { return; }
    var item = Item { text: [], done: false };
    var n = text.len;
    if n > TEXT_MAX { n = TEXT_MAX; }
    item.text.append(text[..n]);
    st.items[st.n] = item;
    st.n += 1;
}

// --- drawing ----------------------------------------------------------------

fn draw(c: tui::Canvas&, app: tui::App&, st: State&) {
    let th = app.theme;
    let all = tui::rect(0, 0, c.w, c.h);
    let body, footer = tui::split_v(all, c.h - 2);
    let inner = tui::panel(c, body, " todo ", th);

    // the field, with a prompt at its left
    let add_r, list_r = tui::split_v(inner, 2);
    tui::draw_text(c, add_r, add_r.x, add_r.y, "> ", tui::th_key(th));
    let field = tui::rect(add_r.x + 2, add_r.y, add_r.w - 2, 1);
    tui::set_cursor(app, tui::input(c, field, st.field, true, th));

    tui::hr(c, list_r, list_r.y, tui::th_border(th));
    let rows = tui::rect(list_r.x, list_r.y + 1, list_r.w, list_r.h - 1);
    tui::list_scroll(st.list, rows.h, st.n);
    draw_rows(c, rows, st, th);
    tui::scrollbar(c, rows, st.list.top, rows.h, st.n, th);

    // how much is left, counted rather than stored: a derived number has no
    // way to go stale
    var open: i32 = 0;
    var i: i32 = 0;
    while i < st.n { if !st.items[i].done { open += 1; } i += 1; }
    var left: u8[>..] = [];
    format(left, st.n - open, "/", st.n, " done");
    tui::status(c, tui::row_at(footer, 0, 2), if open > 0 { "  keep going" } else { "  all clear" }, left[..], th);
    tui::help(c, tui::row_at(footer, 1, 2),
              ["enter", "space", "x", "q"],
              ["add", "toggle", "delete", "quit"], th);
}

fn draw_rows(c: tui::Canvas&, r: tui::Rect, st: State&, th: tui::Theme) {
    var row: i32 = 0;
    while row < r.h {
        let idx = st.list.top + row;
        if idx >= st.n { break; }
        let item = st.items[idx];
        let y = r.y + row;
        let sel = idx == st.list.sel;
        let line = tui::rect(r.x, y, r.w, 1);
        if sel { tui::fill_rect(c, line, ' ', tui::th_selected(th)); }

        let base = if sel { tui::th_selected(th) } else { tui::th_text(th) };
        // a ticked item is dim and struck through; the selection keeps its
        // colours, so the row stays legible
        var text_style = base;
        var mark = "[ ]";
        if item.done {
            mark = "[x]";
            if !sel { text_style = tui::strike(tui::dim(base)); }
        }
        tui::draw_text(c, line, r.x + 1, y, mark, if sel { base } else { tui::th_ok(th) });
        let tail = tui::rect(r.x + 5, y, r.w - 6, 1);
        tui::ellipsis(c, tail, tail.x, y, item.text[..], text_style);
        row += 1;
    }
}
