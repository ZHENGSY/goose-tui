// tests/decoder.goose -- the byte stream in, the events out.
//
// Every case here is a record of what a real terminal sent, fed to the
// decoder without a terminal in the loop. That is the whole point of the
// state machine: sequences split across reads, a lone ESC, and a paste in
// three chunks are ordinary inputs, not emergencies.
//
//   goose run tests/decoder.goose

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
    characters();
    named_keys();
    arrows();
    modifiers();
    function_keys();
    mouse();
    paste();
    escapes();
    malformed();
    print(passed, " passed, ", failed, " failed");
    if failed > 0 { exit(1); }
}

// --- harness ----------------------------------------------------------------

// Feeds `bytes` and returns every event they completed. With `do_flush` the
// clock is advanced past the ESC timeout afterwards, which resolves a lone
// escape the way the run loop does.
fn events(bytes: const u8[:], do_flush: bool) -> tui::Event[>..] {
    var d = tui::decoder();
    var evs: tui::Event[>..] = [];
    tui::feed(d, bytes, 1000) { ev => evs.push(ev) };
    if do_flush {
        tui::flush(d, 1000 + tui::ESC_TIMEOUT_MS + 1) { ev => evs.push(ev) };
    }
    return evs;
}

fn key_name(k: tui::Key) -> const u8[:] {
    match k {
        Char _ => { return "char"; },
        Enter => { return "enter"; },
        Tab => { return "tab"; },
        Backspace => { return "backspace"; },
        Esc => { return "esc"; },
        Delete => { return "delete"; },
        Insert => { return "insert"; },
        Up => { return "up"; },
        Down => { return "down"; },
        Left => { return "left"; },
        Right => { return "right"; },
        Home => { return "home"; },
        End => { return "end"; },
        PageUp => { return "pageup"; },
        PageDown => { return "pagedown"; },
        F f => {
            if f.n == 1 { return "f1"; }
            if f.n == 2 { return "f2"; }
            if f.n == 3 { return "f3"; }
            if f.n == 4 { return "f4"; }
            if f.n == 5 { return "f5"; }
            if f.n == 6 { return "f6"; }
            if f.n == 7 { return "f7"; }
            if f.n == 8 { return "f8"; }
            if f.n == 9 { return "f9"; }
            if f.n == 10 { return "f10"; }
            if f.n == 11 { return "f11"; }
            if f.n == 12 { return "f12"; }
            return "f?";
        },
        Unknown => { return "unknown"; },
    }
}

// One event as a short, diffable line: "char:a", "char:a+ctrl", "up+shift",
// "mouse:3,4,press,0", "paste:hi", "resize:80x24".
fn ev_str(ev: tui::Event) -> u8[>..] {
    var s: u8[>..] = [];
    match ev {
        None => { s.append("none"); },
        Key e => {
            s.append(key_name(e.key));
            if tui::is_key(ev) && tui::key_char(ev) > 0 {
                s.push(':');
                push_utf8(s, tui::key_char(ev));
            }
            if e.mods != 0 {
                s.push('+');
                var first = true;
                if (e.mods & tui::MOD_SHIFT) != 0 { s.append("shift"); first = false; }
                if (e.mods & tui::MOD_ALT) != 0 {
                    if !first { s.push('-'); }
                    s.append("alt");
                    first = false;
                }
                if (e.mods & tui::MOD_CTRL) != 0 {
                    if !first { s.push('-'); }
                    s.append("ctrl");
                }
            }
        },
        Mouse e => {
            s.append("mouse:");
            format(s, e.x as i64);
            s.push(',');
            format(s, e.y as i64);
            s.push(',');
            if e.kind == tui::MOUSE_PRESS { s.append("press"); }
            if e.kind == tui::MOUSE_RELEASE { s.append("release"); }
            if e.kind == tui::MOUSE_DRAG { s.append("drag"); }
            if e.kind == tui::MOUSE_MOVE { s.append("move"); }
            if e.kind == tui::MOUSE_SCROLL_UP { s.append("wheelup"); }
            if e.kind == tui::MOUSE_SCROLL_DOWN { s.append("wheeldown"); }
            s.push(',');
            format(s, e.button as i64);
        },
        Paste e => {
            s.append("paste:");
            s.append(e.text[..(e.len as i64)]);
        },
        Resize e => {
            s.append("resize:");
            format(s, e.w as i64);
            s.push('x');
            format(s, e.h as i64);
        },
    }
    return s;
}

// The single event `bytes` produce, or "none".
fn one(bytes: const u8[:]) -> u8[>..] {
    let evs = events(bytes, false);
    if evs.len == 0 { return "none"; }
    return ev_str(evs[0]);
}

fn check1(name: const u8[:], bytes: const u8[:], want: const u8[:]) {
    let got = one(bytes);
    if got == want { passed += 1; return; }
    failed += 1;
    print("FAIL  ", name, ": want ", want, " got ", got);
}

// --- cases ------------------------------------------------------------------

fn characters() {
    check1("letter", "a", "char:a");
    check1("digit", "7", "char:7");
    check1("space", " ", "char: ");
    check1("punct", "/", "char:/");
    check1("utf8 latin", "\xC3\xA9", "char:é");         // é
    check1("utf8 cjk", "\xE4\xB8\xAD", "char:中");
    check1("utf8 emoji", "\xF0\x9F\x99\x82", "char:🙂");

    // two characters in one read are two events
    let evs = events("ab", false);
    check("two chars", evs.len == 2 && ev_str(evs[0]) == "char:a" && ev_str(evs[1]) == "char:b");

    // a sequence split across reads still decodes
    var d = tui::decoder();
    var evs2: tui::Event[>..] = [];
    tui::feed(d, "\xE4\xB8", 0) { ev => evs2.push(ev) };
    check("split utf8: half an event", evs2.len == 0);
    tui::feed(d, "\xAD", 0) { ev => evs2.push(ev) };
    check("split utf8: completes", evs2.len == 1 && ev_str(evs2[0]) == "char:中");
}

fn named_keys() {
    check1("enter cr", "\r", "enter");
    check1("enter lf", "\n", "enter");
    check1("tab", "\t", "tab");
    check1("backspace del", "\x7F", "backspace");
    check1("backspace bs", "\x08", "backspace");
    check1("ctrl-a", "\x01", "char:a+ctrl");
    check1("ctrl-space", "\x00", "char: +ctrl");
    check1("ctrl-z", "\x1A", "char:z+ctrl");
    check1("ctrl-c", "\x03", "char:c+ctrl");
}

fn arrows() {
    check1("up csi", "\x1b[A", "up");
    check1("down csi", "\x1b[B", "down");
    check1("right csi", "\x1b[C", "right");
    check1("left csi", "\x1b[D", "left");
    check1("home csi", "\x1b[H", "home");
    check1("end csi", "\x1b[F", "end");
    check1("up ss3", "\x1bOA", "up");
    check1("right ss3", "\x1bOC", "right");
    check1("shift-tab", "\x1b[Z", "tab+shift");
    check1("home tilde", "\x1b[1~", "home");
    check1("end tilde", "\x1b[4~", "end");
    check1("insert", "\x1b[2~", "insert");
    check1("delete", "\x1b[3~", "delete");
    check1("pageup", "\x1b[5~", "pageup");
    check1("pagedown", "\x1b[6~", "pagedown");
    check1("home 7", "\x1b[7~", "home");
    check1("end 8", "\x1b[8~", "end");
}

fn modifiers() {
    check1("ctrl-up", "\x1b[1;5A", "up+ctrl");
    check1("shift-right", "\x1b[1;2C", "right+shift");
    check1("alt-left", "\x1b[1;3D", "left+alt");
    check1("ctrl-shift-down", "\x1b[1;6B", "down+shift-ctrl");
    check1("ctrl-delete", "\x1b[3;5~", "delete+ctrl");
    // alt+x: ESC then the byte, no bracket
    check1("alt-x", "\x1bx", "char:x+alt");
    check1("meta-enter", "\x1b\r", "char:\r+alt");
    // CSI u (kitty): codepoint, then the modifier parameter
    check1("csi-u letter", "\x1b[97u", "char:a");
    check1("csi-u ctrl", "\x1b[97;5u", "char:a+ctrl");
    check1("csi-u shift-enter", "\x1b[13;2u", "char:\r+shift");
}

fn function_keys() {
    check1("f1 ss3", "\x1bOP", "f1");
    check1("f4 ss3", "\x1bOS", "f4");
    check1("f5 tilde", "\x1b[15~", "f5");
    check1("f12", "\x1b[24~", "f12");
    check1("f1 ctrl", "\x1b[11;5~", "f1+ctrl");
}

fn mouse() {
    check1("press", "\x1b[<0;12;5M", "mouse:11,4,press,0");
    check1("release", "\x1b[<0;12;5m", "mouse:11,4,release,0");
    check1("middle press", "\x1b[<1;3;3M", "mouse:2,2,press,1");
    check1("drag", "\x1b[<32;4;4M", "mouse:3,3,drag,0");
    check1("wheel up", "\x1b[<64;9;9M", "mouse:8,8,wheelup,0");
    check1("wheel down", "\x1b[<65;9;9M", "mouse:8,8,wheeldown,0");

    let evs = events("\x1b[<0;2;2M", false);
    check("mouse is_mouse", evs.len == 1 && tui::is_mouse(evs[0]));
    check("mouse is not key", evs.len == 1 && !tui::is_key(evs[0]));
    let m = tui::mouse_of(evs[0]);
    check("mouse_of fields", m.x == 1 && m.y == 1 && m.button == 0 && m.kind == tui::MOUSE_PRESS);
    check("mouse press", tui::mouse_is_press(evs[0]));

    let kec = events("a", false);
    check("key is not a mouse", !tui::is_mouse(kec[0]));
    check("mouse_of on a key misses", tui::mouse_of(kec[0]).x == -1);
}

fn paste() {
    check1("paste", "\x1b[200~hi\x1b[201~", "paste:hi");
    check1("paste empty", "\x1b[200~\x1b[201~", "none");
    check1("paste newline", "\x1b[200~a\nb\x1b[201~", "paste:a\nb");
    check1("paste utf8", "\x1b[200~中\x1b[201~", "paste:中");
    // the terminator itself is never part of the text
    check1("paste 201 body", "\x1b[200~x\x1b[201~", "paste:x");

    // a paste split across three reads
    var d = tui::decoder();
    var evs: tui::Event[>..] = [];
    tui::feed(d, "\x1b[200~he", 0) { ev => evs.push(ev) };
    check("paste partial: nothing yet", evs.len == 0);
    tui::feed(d, "llo", 0) { ev => evs.push(ev) };
    check("paste partial: still nothing", evs.len == 0);
    tui::feed(d, "\x1b[201~", 0) { ev => evs.push(ev) };
    check("paste partial: arrives", evs.len == 1 && ev_str(evs[0]) == "paste:hello");

    // an escape inside the paste is text, not a sequence
    check1("paste keeps esc", "\x1b[200~a\x1b[Ab\x1b[201~", "paste:a\x1b[Ab");

    // paste_append copies into a caller's buffer
    let pev = events("\x1b[200~abc\x1b[201~", false);
    var out: u8[>..] = [];
    let n = tui::paste_append(pev[0], out);
    check("paste_append", n == 3 && out.len == 3 && out[0] == 'a' && out[2] == 'c');
    var empty: u8[>..] = [];
    check("paste_append on a key", tui::paste_append(events("a", false)[0], empty) == 0);
    check("paste is_paste", tui::is_paste(pev[0]));
}

fn escapes() {
    // a lone ESC waits for the timeout, then becomes the Escape key
    var d = tui::decoder();
    var evs: tui::Event[>..] = [];
    tui::feed(d, "\x1b", 1000) { ev => evs.push(ev) };
    check("lone esc waits", evs.len == 0);
    tui::flush(d, 1000 + tui::ESC_TIMEOUT_MS) { ev => evs.push(ev) };
    check("lone esc flushes", evs.len == 1 && ev_str(evs[0]) == "esc");

    // too early: still ambiguous
    var d2 = tui::decoder();
    var evs2: tui::Event[>..] = [];
    tui::feed(d2, "\x1b", 1000) { ev => evs2.push(ev) };
    tui::flush(d2, 1000 + tui::ESC_TIMEOUT_MS - 1) { ev => evs2.push(ev) };
    check("esc wait is real", evs2.len == 0);

    // ESC ESC: the first is an Escape key, the second starts over
    let evs3 = events("\x1b\x1b", false);
    check("esc esc", evs3.len == 1 && ev_str(evs3[0]) == "esc");

    check("esc then char is alt", one("\x1bq") == "char:q+alt");
}

fn malformed() {
    check1("unknown csi", "\x1b[99~", "none");
    check1("unknown csi letter", "\x1b[1;2Q", "none");
    check1("csi with junk then final", "\x1b[?25h", "none");
    // a truncated UTF-8 lead byte becomes U+FFFD rather than a stall
    check1("lone continuation at ground", "\x80", "char:\xEF\xBF\xBD");
    let trunc = events("\xE4", true);
    check("truncated lead flushes", trunc.len == 1 && ev_str(trunc[0]) == "char:\xEF\xBF\xBD");

    // an over-long parameter list cannot overflow the decoder
    let long = "\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20A";
    let evs = events(long, false);
    check("many params cannot overflow", evs.len == 1 && tui::key_is_any(evs[0], tui::Key.Up));
}
