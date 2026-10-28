// tui/keys.goose -- the key, mouse and paste decoder.
//
// Input is a byte stream, not a list of key presses. This module is a
// resumable state machine over that stream: it needs no allocation, it
// survives a sequence split across two read() calls, and a test can feed it
// the exact bytes a terminal sends without a terminal being involved.
//
//   ground --0x1b--> esc --[--> csi --final--> event
//                        --O--> ss3 --char---> event
//                        --x--> alt+x
//   ground --c2..f4--> utf8 --continuations--> Char
//   csi 200~ --------------------------------> paste .. csi 201~
//
// A lone ESC is ambiguous until either another byte arrives or 25 ms pass;
// `flush` resolves it, which is why a bare Escape key works at all.

namespace tui;

import std;

let MOD_SHIFT: u8 = 1;
let MOD_ALT: u8 = 2;
let MOD_CTRL: u8 = 4;

enum Key {
    Char { cp: u32 },
    Enter,
    Tab,
    Backspace,
    Esc,
    Delete,
    Insert,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    F { n: u8 },
    Unknown,
}

let MOUSE_PRESS: u8 = 0;
let MOUSE_RELEASE: u8 = 1;
let MOUSE_DRAG: u8 = 2;
let MOUSE_MOVE: u8 = 3;
let MOUSE_SCROLL_UP: u8 = 4;
let MOUSE_SCROLL_DOWN: u8 = 5;

enum Event {
    Key { key: Key, mods: u8 },
    Mouse { x: i32, y: i32, button: u8, kind: u8 },
    // A bracketed paste carries its bytes inline, with the length: a paste
    // longer than the buffer arrives as several events.
    Paste { text: u8[..256], len: i32 },
    Resize { w: i32, h: i32 },
    None,
}

// --- decoder ----------------------------------------------------------------

let ST_GROUND: u8 = 0;
let ST_ESC: u8 = 1;
let ST_CSI: u8 = 2;
let ST_SS3: u8 = 3;
let ST_UTF8: u8 = 4;
let ST_PASTE: u8 = 5;

let ESC_TIMEOUT_MS: i64 = 25;

struct Decoder {
    state: u8,
    esc_at: i64,
    params: u8[..24],
    np: i32,
    cp: u32,
    need: u8,
    seen: u8,
    mods: u8,
    paste: u8[..256],
    npaste: i32,
}

fn decoder() -> Decoder {
    return Decoder {
        state: ST_GROUND, esc_at: 0,
        params: [0; 24], np: 0,
        cp: 0, need: 0, seen: 0, mods: 0,
        paste: [0; 256], npaste: 0,
    };
}

fn reset_sequence(d: Decoder&) {
    d.state = ST_GROUND;
    d.np = 0;
    d.cp = 0;
    d.need = 0;
    d.seen = 0;
    d.mods = 0;
}

fn push_param(d: Decoder&, b: u8) {
    if d.np < 24 { d.params[d.np] = b; d.np += 1; }
}

fn key_event(key: Key, mods: u8) -> Event, bool {
    return Event.Key { key: key, mods: mods }, true;
}

fn no_event() -> Event, bool { return Event.None, false; }

// Feeds one byte. Returns the event it completed, if any.
fn decode_byte(d: Decoder&, b: u8, now_ms: i64) -> Event, bool {
    if d.state == ST_GROUND {
        if b == 0x1b {
            d.state = ST_ESC;
            d.esc_at = now_ms;
            d.mods = 0;
            return no_event();
        }
        if b == '\r' || b == '\n' { return key_event(Key.Enter, 0); }
        if b == '\t' { return key_event(Key.Tab, 0); }
        if b == 0x7f || b == 0x08 { return key_event(Key.Backspace, 0); }
        if b < 0x20 {
            // Ctrl-A is 0x01: the byte plus 0x60 is the letter.
            if b == 0 { return key_event(Key.Char { cp: 32 }, MOD_CTRL); }
            let cp: u32 = b;
            return key_event(Key.Char { cp: cp + 96 }, MOD_CTRL);
        }
        if b < 0x80 { return key_event(Key.Char { cp: b }, 0); }
        // a multi-byte sequence
        let need = utf8_len(b);
        if need == 1 {
            // a continuation byte or an impossible lead: one replacement char
            return key_event(Key.Char { cp: U_FFFD }, 0);
        }
        d.need = need as u8;
        d.seen = 1;
        d.cp = utf8_payload(b);
        d.state = ST_UTF8;
        return no_event();
    }

    if d.state == ST_UTF8 {
        d.cp = (d.cp << 6) | (b & 0x3F);
        d.seen += 1;
        if d.seen >= d.need {
            let cp = d.cp;
            let mods = d.mods;
            d.state = ST_GROUND;
            d.mods = 0;
            if cp == 0 { return no_event(); }
            return key_event(Key.Char { cp: cp }, mods);
        }
        return no_event();
    }

    if d.state == ST_ESC {
        if b == '[' {
            d.state = ST_CSI;
            d.np = 0;
            return no_event();
        }
        if b == 'O' {
            d.state = ST_SS3;
            return no_event();
        }
        if b == 0x1b {
            // ESC ESC: the first was a real Escape, this one starts a new one
            d.esc_at = now_ms;
            return key_event(Key.Esc, d.mods);
        }
        let mods = d.mods | MOD_ALT;
        d.state = ST_GROUND;
        d.mods = 0;
        if b < 0x80 { return key_event(Key.Char { cp: b }, mods); }
        d.mods = mods;
        d.need = utf8_len(b) as u8;
        d.seen = 1;
        d.cp = utf8_payload(b);
        d.state = ST_UTF8;
        return no_event();
    }

    if d.state == ST_SS3 {
        d.state = ST_GROUND;
        if b == 'A' { return key_event(Key.Up, d.mods); }
        if b == 'B' { return key_event(Key.Down, d.mods); }
        if b == 'C' { return key_event(Key.Right, d.mods); }
        if b == 'D' { return key_event(Key.Left, d.mods); }
        if b == 'H' { return key_event(Key.Home, d.mods); }
        if b == 'F' { return key_event(Key.End, d.mods); }
        if b == 'P' { return key_event(Key.F { n: 1 }, d.mods); }
        if b == 'Q' { return key_event(Key.F { n: 2 }, d.mods); }
        if b == 'R' { return key_event(Key.F { n: 3 }, d.mods); }
        if b == 'S' { return key_event(Key.F { n: 4 }, d.mods); }
        return no_event();
    }

    if d.state == ST_PASTE {
        if d.npaste < 256 { d.paste[d.npaste] = b; d.npaste += 1; }
        if paste_done(d) {
            let n = d.npaste - 6;
            var text: u8[..256] = [0; 256];
            var i: i32 = 0;
            while i < n { text[i] = d.paste[i]; i += 1; }
            d.npaste = 0;
            d.state = ST_GROUND;
            if n <= 0 { return no_event(); }
            return Event.Paste { text: text, len: n }, true;
        }
        if d.npaste >= 256 {
            // a paste longer than the buffer arrives in chunks
            var text: u8[..256] = [0; 256];
            var i: i32 = 0;
            while i < 256 { text[i] = d.paste[i]; i += 1; }
            d.npaste = 0;
            return Event.Paste { text: text, len: 256 }, true;
        }
        return no_event();
    }

    // ST_CSI: parameters and intermediates until a final byte at 0x40..0x7e
    if b >= 0x40 && b <= 0x7e {
        let ev, ok = dispatch_csi(d, b);
        // A dispatcher that starts something new (a bracketed paste) keeps its
        // state; everything else is a complete, self-contained sequence.
        if d.state != ST_PASTE { reset_sequence(d); }
        return ev, ok;
    }
    push_param(d, b);
    return no_event();
}

fn utf8_payload(b: u8) -> u32 {
    if (b & 0xF0) == 0xE0 { return b & 0x0F; }
    if (b & 0xF8) == 0xF0 { return b & 0x07; }
    return b & 0x1F;
}

// True when the paste buffer ends with ESC [ 2 0 1 ~ .
fn paste_done(d: Decoder&) -> bool {
    if d.npaste < 6 { return false; }
    let n = d.npaste - 6;
    return d.paste[n] == 0x1b && d.paste[n + 1] == '['
        && d.paste[n + 2] == '2' && d.paste[n + 3] == '0'
        && d.paste[n + 4] == '1' && d.paste[n + 5] == '~';
}

// --- CSI --------------------------------------------------------------------

// The parameter bytes of this CSI, as a string: "1;5", "<0;12;5", "".
fn params_str(d: Decoder&) -> u8[..24] {
    var s: u8[..24] = [0; 24];
    var i: i32 = 0;
    while i < d.np && i < 24 { s[i] = d.params[i]; i += 1; }
    return s;
}

// Parameter k (0-based) of a CSI, or -1.
fn param_at(d: Decoder&, k: i32) -> i32 {
    var idx: i32 = 0;
    var i: i32 = 0;
    var v: i32 = 0;
    var any = false;
    while i < d.np {
        let b = d.params[i];
        if b == ';' {
            if idx == k { if any { return v; } return -1; }
            idx += 1;
            v = 0;
            any = false;
        } else if b >= '0' && b <= '9' {
            v = v * 10 + (b as i32 - 48);
            any = true;
        }
        i += 1;
    }
    if idx == k { if any { return v; } return -1; }
    return -1;
}

// The xterm modifier parameter (the second one) as our MOD_* bits.
fn param_mods(d: Decoder&) -> u8 {
    let m = param_at(d, 1);
    if m <= 1 { return 0; }
    let n = m - 1;
    var out: u8 = 0;
    if (n & 1) != 0 { out = out | MOD_SHIFT; }
    if (n & 2) != 0 { out = out | MOD_ALT; }
    if (n & 4) != 0 { out = out | MOD_CTRL; }
    return out;
}

fn dispatch_csi(d: Decoder&, final: u8) -> Event, bool {
    let mods = param_mods(d);
    if final == 'A' { return key_event(Key.Up, mods); }
    if final == 'B' { return key_event(Key.Down, mods); }
    if final == 'C' { return key_event(Key.Right, mods); }
    if final == 'D' { return key_event(Key.Left, mods); }
    if final == 'H' { return key_event(Key.Home, mods); }
    if final == 'F' { return key_event(Key.End, mods); }
    if final == 'Z' { return key_event(Key.Tab, mods | MOD_SHIFT); }
    if final == 'M' { return sgr_mouse(d, false); }
    if final == 'm' { return sgr_mouse(d, true); }
    if final == 'u' { return csi_u(d); }
    if final == '~' { return tilde_key(d, mods); }
    return no_event();
}
fn tilde_key(d: Decoder&, mods: u8) -> Event, bool {
    let p = param_at(d, 0);
    if p == 1 || p == 7 { return key_event(Key.Home, mods); }
    if p == 2 { return key_event(Key.Insert, mods); }
    if p == 3 { return key_event(Key.Delete, mods); }
    if p == 4 || p == 8 { return key_event(Key.End, mods); }
    if p == 5 { return key_event(Key.PageUp, mods); }
    if p == 6 { return key_event(Key.PageDown, mods); }
    if p == 11 { return key_event(Key.F { n: 1 }, mods); }
    if p == 12 { return key_event(Key.F { n: 2 }, mods); }
    if p == 13 { return key_event(Key.F { n: 3 }, mods); }
    if p == 14 { return key_event(Key.F { n: 4 }, mods); }
    if p == 15 { return key_event(Key.F { n: 5 }, mods); }
    if p == 17 { return key_event(Key.F { n: 6 }, mods); }
    if p == 18 { return key_event(Key.F { n: 7 }, mods); }
    if p == 19 { return key_event(Key.F { n: 8 }, mods); }
    if p == 20 { return key_event(Key.F { n: 9 }, mods); }
    if p == 21 { return key_event(Key.F { n: 10 }, mods); }
    if p == 23 { return key_event(Key.F { n: 11 }, mods); }
    if p == 24 { return key_event(Key.F { n: 12 }, mods); }
    if p == 200 {
        d.state = ST_PASTE;
        d.npaste = 0;
        return no_event();
    }
    return no_event();
}

// kitty's CSI u: ESC [ <codepoint> [; <mods>] u
fn csi_u(d: Decoder&) -> Event, bool {
    let cp = param_at(d, 0);
    if cp <= 0 { return no_event(); }
    return Event.Key { key: Key.Char { cp: cp as u32 }, mods: param_mods(d) }, true;
}

// SGR mouse: ESC [ < b ; x ; y M   (press, drag, wheel)  and  ... m (release)
// param_at ignores the leading '<', so the numbers are already in place.
fn sgr_mouse(d: Decoder&, release: bool) -> Event, bool {
    let b = param_at(d, 0);
    let x = param_at(d, 1);
    let y = param_at(d, 2);
    var btn: u8 = 0;
    var kind: u8 = MOUSE_PRESS;
    if (b & 64) != 0 {
        if (b & 1) != 0 { kind = MOUSE_SCROLL_DOWN; } else { kind = MOUSE_SCROLL_UP; }
    } else {
        btn = (b & 3) as u8;
        if release { kind = MOUSE_RELEASE; }
        else if (b & 32) != 0 { kind = MOUSE_DRAG; }
    }
    return Event.Mouse { x: x - 1, y: y - 1, button: btn, kind: kind }, true;
}

// --- feeding ----------------------------------------------------------------

// Feeds bytes, reporting each completed event through the trailing block.
fn feed<F>(d: Decoder&, bytes: u8[:], now_ms: i64) {
    for b in bytes {
        let ev, ok = decode_byte(d, b, now_ms);
        if ok { F(ev); }
    }
}

// Called once a frame with no bytes: turns a lone ESC into the Escape key, and
// an unfinished UTF-8 sequence into one replacement character. Both mean the
// stream stopped mid-sequence, which a terminal does only when it is gone.
fn flush<F>(d: Decoder&, now_ms: i64) {
    if d.state == ST_ESC && now_ms - d.esc_at >= ESC_TIMEOUT_MS {
        d.state = ST_GROUND;
        F(Event.Key { key: Key.Esc, mods: d.mods });
        d.mods = 0;
        return;
    }
    if d.state == ST_UTF8 {
        let mods = d.mods;
        reset_sequence(d);
        F(Event.Key { key: Key.Char { cp: U_FFFD }, mods: mods });
    }
}

// --- reading events ---------------------------------------------------------

fn is_none(ev: Event) -> bool {
    match ev { None => { return true; }, _ => {} }
    return false;
}

fn key_of(ev: Event) -> Key {
    var k: Key = Key.Unknown;
    match ev { Key e => { k = e.key; }, _ => {} }
    return k;
}

fn mods_of(ev: Event) -> u8 {
    var m: u8 = 0;
    match ev { Key e => { m = e.mods; }, _ => {} }
    return m;
}

// The code point of a character key, or 0 for any other event.
fn key_char(ev: Event) -> u32 {
    let k = key_of(ev);
    match k { Char c => { return c.cp; }, _ => {} }
    return 0;
}

// True when the event is this character typed with no modifier.
fn key_is(ev: Event, ch: u8) -> bool {
    return key_char(ev) == ch && mods_of(ev) == 0;
}

// True when the event is this character typed with Ctrl held.
fn key_is_ctrl(ev: Event, ch: u8) -> bool {
    return key_char(ev) == ch && (mods_of(ev) & MOD_CTRL) != 0;
}

// True for a named key (tui::Up, tui::Enter, tui::F5 ...). Enums compare
// structurally, so a named-key test is one equality.
fn key_is_any(ev: Event, want: Key) -> bool {
    return key_of(ev) == want;
}

// Ctrl+C: the run loop quits on it unless you handle it first.
fn is_ctrl_c(ev: Event) -> bool {
    return key_is_ctrl(ev, 'c');
}

// --- event kinds ------------------------------------------------------------

fn is_key(ev: Event) -> bool {
    match ev { Key _ => { return true; }, _ => {} }
    return false;
}

fn is_mouse(ev: Event) -> bool {
    match ev { Mouse _ => { return true; }, _ => {} }
    return false;
}

fn is_paste(ev: Event) -> bool {
    match ev { Paste _ => { return true; }, _ => {} }
    return false;
}

fn is_resize(ev: Event) -> bool {
    match ev { Resize _ => { return true; }, _ => {} }
    return false;
}

// A mouse event's fields as a value. Any other event gives x = y = -1, so a
// hit test against it simply misses.
struct Mouse { x: i32, y: i32, button: u8, kind: u8 }

fn mouse_of(ev: Event) -> Mouse {
    var m = Mouse { x: -1, y: -1, button: 0, kind: MOUSE_PRESS };
    match ev {
        Mouse e => {
            m = Mouse { x: e.x, y: e.y, button: e.button, kind: e.kind };
        },
        _ => {},
    }
    return m;
}

fn mouse_is_press(ev: Event) -> bool {
    let m = mouse_of(ev);
    return m.x >= 0 && m.kind == MOUSE_PRESS;
}

// Appends a paste's bytes to `out` and returns how many arrived: the safe way
// to keep pasted text, since the event's bytes do not outlive the frame.
fn paste_append(ev: Event, out: u8[>..]&) -> i32 {
    var n: i32 = 0;
    match ev {
        Paste e => {
            var i: i32 = 0;
            while i < e.len { out.push(e.text[i]); i += 1; }
            n = e.len;
        },
        _ => {},
    }
    return n;
}
