// 06 -- dashboard: animation, tabs, and a mouse.
//
// Three metrics sampled from a wandering generator, a sparkline history each,
// a process table, and three tabs. Nothing is stored on a timer: an idle frame
// carries `Event.None`, and `app.now_ms` says how long it has been, so the
// sampling rate is a property of the program, not of the loop.
//
//   goose run 06_dashboard.goose
//   left/right or click  switch tabs     up/down  table
//   q  quit

import std;
import tui from "..";
import ._harness;

let TABS: const u8[:][3] = ["dashboard", "activity", "about"];

let PROC_HEADER: const u8[:][4] = ["pid", "name", "cpu", "mem"];

let PROC_ROWS: const u8[:][32] = [
    "412", "goose", "12%", "88 MB",
    "98", "windowserver", "7%", "412 MB",
    "773", "terminal", "2%", "64 MB",
    "1201", "goose-tui", "31%", "12 MB",
    "44", "kernel_task", "4%", "1.2 GB",
    "512", "spotlight", "1%", "204 MB",
    "889", "music", "0%", "156 MB",
    "1330", "python", "18%", "96 MB",
];

let HIST: i32 = 72;

// One metric: the current reading and the history behind it, newest last. The
// history is a fixed array the sample shifts along, so a sample is a small
// copy and never an allocation.
struct Metric { value: f64, hist: f64[..72], n: i32 }

struct State {
    tabs: tui::TabsState,
    table: tui::TableState,
    seed: u32,
    last_ms: i64,
    mouse_on: bool,
    cpu: Metric,
    mem: Metric,
    net: Metric,
}

fn metric(v: f64) -> Metric {
    return Metric { value: v, hist: [0.0; 72], n: 0 };
}

fn main() {
    var t = tui::term();
    var app = tui::app();
    var c = tui::canvas(80, 24);
    var st = State {
        tabs: tui::tabs_state(),
        table: tui::table_state(),
        seed: 0x5EED,
        last_ms: 0,
        mouse_on: false,
        cpu: metric(0.31),
        mem: metric(0.54),
        net: metric(0.12),
    };

    harness::play(app, t, c) { cv, ev =>
        // mouse reporting needs a terminal: a headless run must not emit it
        if t.on && !st.mouse_on { tui::set_mouse(t, true); st.mouse_on = true; }
        update(app, st, ev);
        draw(cv, app, st);
    };
    if t.on { tui::set_mouse(t, false); }
}

fn update(app: tui::App&, st: State&, ev: tui::Event) {
    if tui::key_is(ev, 'q') || tui::key_is_any(ev, tui::Key.Esc) { tui::quit(app); return; }
    if tui::tabs_key(st.tabs, ev, TABS.len) { return; }
    tui::table_key(st.table, ev, PROC_ROWS.len / 4);
    if tui::mouse_is_press(ev) {
        let m = tui::mouse_of(ev);
        if m.y == 0 {
            let hit = tui::tabs_at(tui::rect(0, 0, 80, 2), TABS, m.x);
            if hit >= 0 { st.tabs.sel = hit; }
        }
    }
    // sample on a schedule of the program's own: every 120 ms
    if app.now_ms - st.last_ms >= 120 {
        st.last_ms = app.now_ms;
        sample(st, st.cpu, 0.35, 0.10);
        sample(st, st.mem, 0.55, 0.04);
        sample(st, st.net, 0.20, 0.15);
    }
}

fn sample(st: State&, m: Metric&, base: f64, spread: f64) {
    let r = rand(st);
    let f = (r % 1000) as f64 / 1000.0;          // 0..1
    var v = base + (f - 0.5) * 2.0 * spread;
    if v < 0.02 { v = 0.02; }
    if v > 0.98 { v = 0.98; }
    m.value = v;
    var i: i32 = 1;
    while i < HIST { m.hist[i - 1] = m.hist[i]; i += 1; }
    m.hist[HIST - 1] = v;
    if m.n < HIST { m.n += 1; }
}

fn rand(st: State&) -> u32 {
    var x = st.seed;
    x = x ^ (x << 13);
    x = x ^ (x >> 17);
    x = x ^ (x << 5);
    st.seed = x;
    return x;
}

// --- drawing ----------------------------------------------------------------

fn draw(c: tui::Canvas&, app: tui::App&, st: State&) {
    let th = app.theme;
    let all = tui::rect(0, 0, c.w, c.h);
    let top, rest = tui::split_v(all, 2);
    let body, footer = tui::split_v(rest, rest.h - 2);

    tui::tabs(c, top, st.tabs, TABS, th);

    if st.tabs.sel == 0 {
        draw_dashboard(c, body, st, th);
    } else if st.tabs.sel == 1 {
        draw_activity(c, body, st, th);
    } else {
        draw_about(c, body, th);
    }

    var clock: u8[>..] = [];
    let secs = app.now_ms / 1000;
    format(clock, "t+", secs, "s  frame ", app.frames);
    tui::status(c, tui::row_at(footer, 0, 2), "  goose-tui dashboard", clock[..], th);
    tui::help(c, tui::row_at(footer, 1, 2),
              ["left/right", "click", "q"],
              ["tabs", "a tab", "quit"], th);
}

fn draw_dashboard(c: tui::Canvas&, r: tui::Rect, st: State&, th: tui::Theme) {
    let cards, lower = tui::split_v(r, 8);
    card(c, tui::col_at(cards, 0, 3), "cpu", st.cpu, th);
    card(c, tui::col_at(cards, 1, 3), "memory", st.mem, th);
    card(c, tui::col_at(cards, 2, 3), "network", st.net, th);

    let inner = tui::panel(c, lower, " processes ", th);
    tui::table(c, inner, st.table, PROC_HEADER, PROC_ROWS, 4, [6, 0, 8, 10], th);
}

// A card is a panel whose body is a big number, a gauge and a sparkline: three
// widgets in eight rows of code, because that is all it takes.
fn card(c: tui::Canvas&, r: tui::Rect, title: const u8[:], m: Metric&, th: tui::Theme) {
    let inner = tui::panel(c, r, title, th);
    var pct: u8[>..] = [];
    format(pct, (m.value * 100.0) as i32, "%");
    let big = tui::row_at(inner, 0, 4);
    tui::centered(c, big, pct[..], tui::bold(tui::th_title(th)));
    tui::gauge(c, tui::row_at(inner, 1, 4), m.value, "", th);
    let sp = tui::row_at(inner, 2, 4);
    tui::spark(c, tui::rect(sp.x, sp.y, sp.w, 2), history(m, sp.w), th);
}

// The most recent samples as a slice of the metric's own array: no copy, no
// allocation, and it cannot hand out a reference that outlives the metric
// because it borrows the caller's.
fn history(m: Metric&, width: i32) -> const f64[:] {
    var n = m.n;
    if n > width { n = width; }
    return m.hist[HIST - n..HIST];
}

fn draw_activity(c: tui::Canvas&, r: tui::Rect, st: State&, th: tui::Theme) {
    let inner = tui::panel(c, r, " recent samples ", th);
    var log: u8[>..] = [];
    var i: i32 = 0;
    let n = if st.cpu.n < 20 { st.cpu.n } else { 20 };
    while i < n {
        let k = HIST - 1 - i;
        format(log, "cpu ", (st.cpu.hist[k] * 100.0) as i32, "%   mem ",
               (st.mem.hist[k] * 100.0) as i32, "%   net ",
               (st.net.hist[k] * 100.0) as i32, "%\n");
        i += 1;
    }
    tui::log_view(c, inner, log[..], tui::th_text(th));
}

fn draw_about(c: tui::Canvas&, r: tui::Rect, th: tui::Theme) {
    let inner = tui::panel(c, r, " about ", th);
    tui::para(c, inner, "goose-tui: immediate mode, a cell buffer, a diff. Every frame the draw block says what is on screen; the presenter compares it with the front buffer and writes only the cells that changed. An idle frame writes nothing at all, so a dashboard can sit on a ssh session for a day.", tui::th_text(th));
}
