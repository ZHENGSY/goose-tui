// tui/rect.goose -- rectangles and the layout arithmetic the widgets use.
//
// A Rect is a plain value: pass it by value, return it, store it. Layout is
// integer arithmetic, never a constraint solver, which is exactly the kind
// of code Goose compiles down to a few instructions.

namespace tui;

struct Rect { x: i32, y: i32, w: i32, h: i32 }

fn rect(x: i32, y: i32, w: i32, h: i32) -> Rect {
    var r = Rect { x: x, y: y, w: w, h: h };
    if r.w < 0 { r.w = 0; }
    if r.h < 0 { r.h = 0; }
    return r;
}

fn right(r: Rect) -> i32 { return r.x + r.w; }
fn bottom(r: Rect) -> i32 { return r.y + r.h; }
fn is_empty(r: Rect) -> bool { return r.w <= 0 || r.h <= 0; }
fn area(r: Rect) -> i32 { return r.w * r.h; }
fn contains(r: Rect, x: i32, y: i32) -> bool {
    return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h;
}

// Shrink on every side.
fn inset(r: Rect, n: i32) -> Rect {
    return rect(r.x + n, r.y + n, r.w - 2 * n, r.h - 2 * n);
}

fn inset_xy(r: Rect, dx: i32, dy: i32) -> Rect {
    return rect(r.x + dx, r.y + dy, r.w - 2 * dx, r.h - 2 * dy);
}

// Keep only the part of `r` inside `outer`.
fn clip(r: Rect, outer: Rect) -> Rect {
    var x0 = r.x;
    var y0 = r.y;
    var x1 = right(r);
    var y1 = bottom(r);
    if x0 < outer.x { x0 = outer.x; }
    if y0 < outer.y { y0 = outer.y; }
    if x1 > right(outer) { x1 = right(outer); }
    if y1 > bottom(outer) { y1 = bottom(outer); }
    return rect(x0, y0, x1 - x0, y1 - y0);
}

// --- the two splits ---------------------------------------------------------
//
// split_h takes the left column's width; split_v the top row's height.
// The remainder always goes to the second half, so `inset` + two splits tile
// a rectangle with no gap and no overlap at any size.

fn split_h(r: Rect, left: i32) -> Rect, Rect {
    var l = left;
    if l < 0 { l = 0; }
    if l > r.w { l = r.w; }
    return rect(r.x, r.y, l, r.h), rect(r.x + l, r.y, r.w - l, r.h);
}

fn split_v(r: Rect, top: i32) -> Rect, Rect {
    var t = top;
    if t < 0 { t = 0; }
    if t > r.h { t = r.h; }
    return rect(r.x, r.y, r.w, t), rect(r.x, r.y + t, r.w, r.h - t);
}

// Proportional split: the left part takes num/den of the width.
fn split_hw(r: Rect, num: i32, den: i32) -> Rect, Rect {
    if den <= 0 { return split_h(r, 0); }
    return split_h(r, (r.w * num) / den);
}

fn split_vh(r: Rect, num: i32, den: i32) -> Rect, Rect {
    if den <= 0 { return split_v(r, 0); }
    return split_v(r, (r.h * num) / den);
}

// Row i of n, with the remainder spread over the first rows so the rows
// always tile: sum of heights == r.h and row i+1 starts where i ends.
fn row_at(r: Rect, i: i32, n: i32) -> Rect {
    if n <= 0 || i < 0 || i >= n { return rect(r.x, r.y, r.w, 0); }
    let y0 = r.y + (i * r.h) / n;
    let y1 = r.y + ((i + 1) * r.h) / n;
    return rect(r.x, y0, r.w, y1 - y0);
}

fn col_at(r: Rect, i: i32, n: i32) -> Rect {
    if n <= 0 || i < 0 || i >= n { return rect(r.x, r.y, 0, r.h); }
    let x0 = r.x + (i * r.w) / n;
    let x1 = r.x + ((i + 1) * r.w) / n;
    return rect(x0, r.y, x1 - x0, r.h);
}

// A box of the given size, centred in `r`.
fn center(r: Rect, w: i32, h: i32) -> Rect {
    var bw = w;
    var bh = h;
    if bw > r.w { bw = r.w; }
    if bh > r.h { bh = r.h; }
    return rect(r.x + (r.w - bw) / 2, r.y + (r.h - bh) / 2, bw, bh);
}

// --- small scalar helpers the widgets keep needing --------------------------

fn clamp_i32(v: i32, lo: i32, hi: i32) -> i32 {
    if v < lo { return lo; }
    if v > hi { return hi; }
    return v;
}

fn clamp_i64(v: i64, lo: i64, hi: i64) -> i64 {
    if v < lo { return lo; }
    if v > hi { return hi; }
    return v;
}

// Wrap an index into 0..n-1 (n > 0), for menus that cycle.
fn wrap_i64(v: i64, n: i64) -> i64 {
    if n <= 0 { return 0; }
    var r = v % n;
    if r < 0 { r += n; }
    return r;
}
