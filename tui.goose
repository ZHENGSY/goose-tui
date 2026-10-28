// tui/tui.goose -- the terminal, the application object, and the run loop.
//
// This is the package entry point: `import tui from "…"` reaches the names in
// every module of the package, because they all declare `namespace tui`.
//
//   var t = tui::term();
//   if !tui::open(t) { return; }
//   var app = tui::app();
//   var c = tui::canvas(t.w, t.h);
//   tui::run(app, t, c) { cv, ev => … };
//   tui::close(t);
//
// Functions are called with the namespace, never as methods: uniform call
// syntax does not cross a namespace, so `t.open()` does not resolve here.

namespace tui;

import std;
import os;      // clock_ns(); the only thing taken from it
import cell;
import rect;
import keys;
import theme;
import widgets;
import utf8;

// --- the C boundary ---------------------------------------------------------
//
// Six functions, implemented in src/term.c. A struct passed by reference
// crosses as a pointer; a slice crosses as {data, len}.

struct Size { rows: i32, cols: i32 }

extern fn tui_open() -> i32;
extern fn tui_close();
extern fn tui_size(out: Size&) -> i32;
extern fn tui_read(buf: u8[:], ms: i32) -> i32;
extern fn tui_write(s: const u8[:]);
extern fn tui_mouse(on: i32);

// --- terminal ---------------------------------------------------------------

struct Term {
    on: bool,
    w: i32,
    h: i32,
    idle_ms: i32,       // how long a frame waits for input before ticking
    sized: bool,
}

fn term() -> Term {
    return Term { on: false, w: 80, h: 24, idle_ms: 50, sized: false };
}

// Enters raw mode and the alternate screen. False when stdin or stdout is not
// a terminal: the caller decides whether to fall back or to draw to a file
// with tui::screen_text instead.
fn open(t: Term&) -> bool {
    let rc = tui_open();
    t.on = rc == 1;
    if t.on { sync_size(t); }
    return t.on;
}

fn close(t: Term&) {
    if !t.on { return; }
    tui_close();
    t.on = false;
}

// Mouse reporting is off by default so the terminal's own text selection
// keeps working. Turn it on to receive Event.Mouse.
fn set_mouse(t: Term&, on: bool) {
    tui_mouse(if on { 1 } else { 0 });
}

// Re-reads the window size. Returns true when it changed (or on the first
// call), which is the resize signal the run loop delivers as Event.Resize.
fn sync_size(t: Term&) -> bool {
    var s = Size { rows: 0, cols: 0 };
    let ok = tui_size(s);
    if ok == 0 || s.cols <= 0 || s.rows <= 0 { return false; }
    let changed = !t.sized || s.cols != t.w || s.rows != t.h;
    t.w = s.cols;
    t.h = s.rows;
    t.sized = true;
    return changed;
}

// One non-blocking read. 0 = the timeout passed, >0 = bytes, <0 = end of input.
fn poll(t: Term&, buf: u8[:]) -> i32 { return tui_read(buf, t.idle_ms); }

fn write_out(t: Term&, s: const u8[:]) { tui_write(s); }

fn clock_ms() -> i64 { return clock_ns() / 1000000; }

// --- application ------------------------------------------------------------

struct App {
    running: bool,
    theme: Theme,
    quit_on_ctrl_c: bool,
    cursor: Cursor,
    now_ms: i64,
    frames: i64,        // frames drawn since the loop started
}

fn app() -> App {
    return App {
        running: true,
        theme: theme_dark(),
        quit_on_ctrl_c: true,
        cursor: cursor_hidden(),
        now_ms: 0,
        frames: 0,
    };
}

fn quit(a: App&) { a.running = false; }

// Where the hardware cursor goes this frame. Widgets that own a caret return
// a Cursor; pass it on, or leave the cursor hidden.
fn set_cursor(a: App&, cur: Cursor) { a.cursor = cur; }
fn hide_cursor(a: App&) { a.cursor = cursor_hidden(); }

// --- the run loop -----------------------------------------------------------
//
// One frame:
//
//   1. notice a resize, resize the canvas and deliver Event.Resize;
//   2. read whatever input is waiting and deliver one event per event;
//   3. if nothing happened, deliver Event.None so animations can tick;
//   4. diff the canvas against what the terminal shows and write the delta.
//
// The block is called at least once per frame and draws; it may be called
// several times in one frame (once per event), in which case only the last
// call's drawing is presented. Drawing is cheap; presenting is the diff.
//
// `Event.None` is the frame where nothing happened: that is where you advance
// a spinner, using `app.now_ms`.

// Every frame starts from the theme's background, with the cursor hidden: a
// draw block never has to erase what the last frame left behind, and a widget
// that owns a caret asks for it explicitly.
fn begin_frame(a: App&, c: Canvas&) {
    canvas_clear(c, style(a.theme.fg, a.theme.bg));
    a.cursor = cursor_hidden();
}

fn run<F>(a: App&, t: Term&, c: Canvas&) {
    var front: Cell[>..] = [];
    var out: u8[>..] = [];
    var buf: u8[..1024] = [0; 1024];
    var dec = decoder();
    var shown = cursor_hidden();

    invalidate(front);
    while a.running {
        a.now_ms = clock_ms();
        a.frames += 1;

        // 1. geometry
        if sync_size(t) {
            if t.w != c.w || t.h != c.h {
                canvas_resize(c, t.w, t.h);
                invalidate(front);
            }
            begin_frame(a, c);
            F(c, Event.Resize { w: t.w, h: t.h });
        }

        // 2. input: every event waiting, in order
        var got: i32 = 0;
        let n = poll(t, buf[..]);
        if n < 0 {
            // end of input (the terminal went away): leave the loop cleanly
            a.running = false;
            break;
        }
        if n > 0 {
            let now = a.now_ms;
            feed(dec, buf[..(n as i64)], now) { ev =>
                got += 1;
                if a.quit_on_ctrl_c && is_ctrl_c(ev) { a.running = false; }
                begin_frame(a, c);
                F(c, ev);
            };
        }
        flush(dec, a.now_ms) { ev =>
            got += 1;
            begin_frame(a, c);
            F(c, ev);
        };

        // 3. nothing happened: a frame to animate in
        if got == 0 {
            begin_frame(a, c);
            F(c, Event.None);
        }

        // 4. present
        present(out, c, front, a.cursor, shown);
        if out.len > 0 { tui_write(out); }
    }
}

// --- headless ---------------------------------------------------------------
//
// The same draw block, the same decoder, no terminal: `input` is fed as if it
// had been typed, then `ticks` idle frames are delivered (with the clock
// advancing 16 ms per tick, so animations move), and the canvas holds what the
// last frame drew. This is how the tests check behaviour without a pty:
//
//   tui::headless(app, c, "jj\r", 3) { cv, ev => frame(cv, ev) };
//   print(tui::screen_text(c));
//
// Nothing is written anywhere and nothing is measured, so a test is a golden
// comparison of `screen_text`.
fn headless<F>(a: App&, c: Canvas&, input: const u8[:], ticks: i32) {
    var dec = decoder();
    a.now_ms = 0;
    a.frames += 1;
    begin_frame(a, c);
    F(c, Event.None);
    feed(dec, input, a.now_ms) { ev =>
        a.frames += 1;
        begin_frame(a, c);
        F(c, ev);
    };
    flush(dec, a.now_ms) { ev =>
        a.frames += 1;
        begin_frame(a, c);
        F(c, ev);
    };
    var i: i32 = 0;
    while i < ticks && a.running {
        a.now_ms += 16;
        a.frames += 1;
        begin_frame(a, c);
        F(c, Event.None);
        i += 1;
    }
}
