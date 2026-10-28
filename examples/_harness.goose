// examples/_harness.goose -- the six lines every example shares.
//
// A program built with goose-tui needs a terminal, an app, a canvas and a draw
// block. This file adds what only the examples need: a headless mode, so a
// test (or a curious reader) can see the frame without a terminal.
//
//   goose run 05_todo.goose                          interactive
//   goose run 05_todo.goose -- --dump                the first frame, as text
//   goose run 05_todo.goose -- --keys "jjx" --dump   after those keys
//
// A run with stdin not a terminal dumps automatically, so `goose run
// example.goose < /dev/null` works in a script.

namespace harness;

import std;
import tui from "..";

// A resizable must be the last field, so `keys` is.
struct Opt { frames: i32, cols: i32, rows: i32, dump: bool, keys: u8[>..] }

fn options() -> Opt {
    var o = Opt { frames: 3, cols: 78, rows: 22, dump: false, keys: [] };
    let argv = args();
    var i: i64 = 1;
    while i < argv.len {
        let a = argv[i];
        var has_next = i + 1 < argv.len;
        if a == "--keys" && has_next {
            i += 1;
            unescape(o.keys, argv[i]);
        } else if a == "--frames" && has_next {
            i += 1;
            let n, ok = parse_int(argv[i]);
            if ok { o.frames = n as i32; }
        } else if a == "--cols" && has_next {
            i += 1;
            let n, ok = parse_int(argv[i]);
            if ok { o.cols = n as i32; }
        } else if a == "--rows" && has_next {
            i += 1;
            let n, ok = parse_int(argv[i]);
            if ok { o.rows = n as i32; }
        } else if a == "--dump" {
            o.dump = true;
        }
        i += 1;
    }
    return o;
}

// Runs the program: live on a terminal, one headless screen otherwise. The
// canvas is resized to the terminal before the loop starts, so the caller can
// create it at any size.
fn play<F>(a: tui::App&, t: tui::Term&, c: tui::Canvas&) {
    let o = options();
    if o.dump || !tui::open(t) {
        run_headless(a, o) { cv, ev => F(cv, ev) };
        return;
    }
    tui::canvas_resize(c, t.w, t.h);
    tui::run(a, t, c) { cv, ev => F(cv, ev) };
    tui::close(t);
}

fn run_headless<F>(a: tui::App&, o: Opt&) {
    var c = tui::canvas(o.cols, o.rows);
    tui::headless(a, c, o.keys[..], o.frames) { cv, ev => F(cv, ev) };
    let s = tui::screen_text(c);
    if s.len > 0 { print(s[..s.len - 1]); }
}

// --- command line -----------------------------------------------------------

// Expands the escapes a --keys value needs: \n \r \t \e \\ and \xHH, so
// "--keys \"\e[Bj\r\"" types Down, j, Enter.
fn unescape(out: u8[>..]&, s: const u8[:]) {
    var i: i64 = 0;
    while i < s.len {
        let b = s[i];
        if b != '\\' || i + 1 >= s.len {
            out.push(b);
            i += 1;
            continue;
        }
        let e = s[i + 1];
        if e == 'n' { out.push('\n'); i += 2; }
        else if e == 'r' { out.push('\r'); i += 2; }
        else if e == 't' { out.push('\t'); i += 2; }
        else if e == 'e' { out.push('\x1b'); i += 2; }
        else if e == '\\' { out.push('\\'); i += 2; }
        else if e == 'x' && i + 3 < s.len {
            let hi, ok1 = hex_digit(s[i + 2]);
            let lo, ok2 = hex_digit(s[i + 3]);
            if ok1 && ok2 {
                out.push(hi * 16 + lo);
                i += 4;
            } else {
                out.push(b);
                i += 1;
            }
        } else {
            out.push(e);
            i += 2;
        }
    }
}

fn hex_digit(b: u8) -> u8, bool {
    if b >= '0' && b <= '9' { return b - '0', true; }
    if b >= 'a' && b <= 'f' { return b - 'a' + 10, true; }
    if b >= 'A' && b <= 'F' { return b - 'A' + 10, true; }
    return 0, false;
}
