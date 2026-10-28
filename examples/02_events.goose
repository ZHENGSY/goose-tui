// 02 -- events: what the decoder delivers, printed as it arrives.
//
// Every key, mouse, paste and resize becomes one line in a log. This is the
// shortest way to see what a terminal actually sends, and it is how the
// decoder's own tests check the awkward cases:
//
//   goose run 02_events.goose
//   goose run 02_events.goose -- --keys "a\e[B\e[A\e[<0;6;3M\x03"
//
// Mouse reporting is off by default (so the terminal's own selection still
// works); this program turns it on because that is the point.

import std;
import tui from "..";
import ._harness;

struct State { count: i64, log: u8[>..] }

fn main() {
    var t = tui::term();
    var app = tui::app();
    var c = tui::canvas(80, 24);
    var st = State { count: 0, log: [] };

    harness::play(app, t, c) { cv, ev =>
        // `open` ran inside play, so the terminal is ready for mouse modes.
        if st.count == 0 && t.on { tui::set_mouse(t, true); }

        if tui::key_is(ev, 'q') || tui::key_is_any(ev, tui::Key.Esc) {
            tui::quit(app);
        }
        if !tui::is_none(ev) {
            st.count += 1;
            describe(st.log, ev);
            // keep the log bounded: drop the older half when it grows past 4 KB
            if st.log.len > 4096 { keep_tail(st.log, 2048); }
        }
        draw(cv, app, st);
    };

    if t.on { tui::set_mouse(t, false); }
}

fn draw(c: tui::Canvas&, app: tui::App&, st: State&) {
    let th = app.theme;
    let inner = tui::panel(c, tui::rect(0, 0, c.w, c.h), "events", th);
    let head = tui::rect(inner.x + 1, inner.y, inner.w - 2, 1);
    tui::draw_text(c, head, head.x, head.y, "type, click, paste, resize", tui::th_dim(th));
    var count: u8[>..] = [];
    format(count, st.count, " event");
    if st.count != 1 { count.push('s'); }
    tui::draw_text_right(c, head, head.y, count[..], tui::th_dim(th));
    tui::hr(c, inner, inner.y + 1, tui::th_border(th));
    let body = tui::rect(inner.x + 1, inner.y + 2, inner.w - 2, inner.h - 3);
    tui::log_view(c, body, st.log[..], tui::th_text(th));
    let hint = tui::rect(inner.x + 1, inner.y + inner.h - 1, inner.w - 2, 1);
    tui::draw_text(c, hint, hint.x, hint.y, "q quits   ^C quits", tui::th_dim(th));
}

// --- describing an event ----------------------------------------------------

fn describe(log: u8[>..]&, ev: tui::Event) {
    if tui::is_key(ev) {
        format(log, "key    ");
        key_name(log, tui::key_of(ev));
        mods_name(log, tui::mods_of(ev));
    } else if tui::is_mouse(ev) {
        let m = tui::mouse_of(ev);
        format(log, "mouse  ");
        format(log, m.x, ",", m.y, "  ");
        if m.kind == tui::MOUSE_PRESS { log.append("press"); }
        if m.kind == tui::MOUSE_RELEASE { log.append("release"); }
        if m.kind == tui::MOUSE_DRAG { log.append("drag"); }
        if m.kind == tui::MOUSE_SCROLL_UP { log.append("wheel up"); }
        if m.kind == tui::MOUSE_SCROLL_DOWN { log.append("wheel down"); }
        format(log, "  button ", m.button);
    } else if tui::is_paste(ev) {
        var text: u8[>..] = [];
        let n = tui::paste_append(ev, text);
        format(log, "paste  ", n, " bytes: ", text[..]);
    } else if tui::is_resize(ev) {
        var w: i32 = 0;
        var h: i32 = 0;
        match ev { Resize e => { w = e.w; h = e.h; }, _ => {} }
        format(log, "resize ", w, "x", h);
    } else {
        return;
    }
    log.push('\n');
}

fn key_name(out: u8[>..]&, k: tui::Key) {
    match k {
        Char c => {
            out.append("char ");
            if c.cp == ' ' { out.append("space"); }
            else { push_utf8(out, c.cp); }
        },
        Enter => { out.append("enter"); },
        Tab => { out.append("tab"); },
        Backspace => { out.append("backspace"); },
        Esc => { out.append("escape"); },
        Delete => { out.append("delete"); },
        Insert => { out.append("insert"); },
        Up => { out.append("up"); },
        Down => { out.append("down"); },
        Left => { out.append("left"); },
        Right => { out.append("right"); },
        Home => { out.append("home"); },
        End => { out.append("end"); },
        PageUp => { out.append("page up"); },
        PageDown => { out.append("page down"); },
        F f => { format(out, "F", f.n); },
        Unknown => { out.append("unknown"); },
    }
}

fn mods_name(out: u8[>..]&, m: u8) {
    if m == 0 { return; }
    out.append("  (");
    if (m & tui::MOD_CTRL) != 0 { out.append("ctrl "); }
    if (m & tui::MOD_ALT) != 0 { out.append("alt "); }
    if (m & tui::MOD_SHIFT) != 0 { out.append("shift "); }
    out.pop();
    out.append(")");
}

// Keeps the last `n` bytes of `log`: the copy happens before the clear, so the
// slice never outlives what it points into.
fn keep_tail(log: u8[>..]&, n: i64) {
    var tail: u8[>..] = [];
    tail.append(log[log.len - n..]);
    log.clear();
    log.append(tail[..]);
}
