// tui/theme.goose -- a theme is a flat struct of colours.
//
// No trait, no registry, no inheritance: copy it, change a field, pass it.
// A widget takes the theme it is given, and a widget that needs three
// colours takes the one `Style` it was given.

namespace tui;

import cell;

struct Theme {
    fg: u32,          // ordinary text
    bg: u32,          // the screen
    dim: u32,         // secondary text
    accent: u32,      // selection foreground, highlights
    border: u32,      // panel borders
    border_focus: u32,// the focused panel's border
    sel_fg: u32,
    sel_bg: u32,
    title: u32,       // panel titles, tab labels
    ok: u32,
    warn: u32,
    err: u32,
    panel_bg: u32,
}

// --- the shipped themes -----------------------------------------------------

fn theme_dark() -> Theme {
    return Theme {
        fg: rgb(214, 222, 235),
        bg: rgb(20, 22, 28),
        dim: rgb(120, 130, 150),
        accent: rgb(130, 190, 255),
        border: rgb(70, 78, 96),
        border_focus: rgb(130, 190, 255),
        sel_fg: rgb(16, 20, 28),
        sel_bg: rgb(130, 190, 255),
        title: rgb(190, 200, 220),
        ok: rgb(120, 210, 140),
        warn: rgb(240, 200, 110),
        err: rgb(240, 120, 120),
        panel_bg: rgb(26, 29, 38),
    };
}

fn theme_light() -> Theme {
    return Theme {
        fg: rgb(40, 44, 52),
        bg: rgb(250, 250, 250),
        dim: rgb(120, 124, 132),
        accent: rgb(20, 100, 200),
        border: rgb(190, 194, 202),
        border_focus: rgb(20, 100, 200),
        sel_fg: rgb(255, 255, 255),
        sel_bg: rgb(20, 100, 200),
        title: rgb(60, 64, 72),
        ok: rgb(20, 140, 60),
        warn: rgb(180, 110, 0),
        err: rgb(190, 30, 40),
        panel_bg: rgb(242, 243, 246),
    };
}

// The 16-colour fallback: correct on any terminal, including a serial
// console, and the theme to use when truecolor is not available.
fn theme_mono() -> Theme {
    return Theme {
        fg: ansi(7), bg: ansi(0), dim: ansi(8), accent: ansi(15),
        border: ansi(8), border_focus: ansi(15),
        sel_fg: ansi(0), sel_bg: ansi(7),
        title: ansi(15), ok: ansi(2), warn: ansi(3), err: ansi(1),
        panel_bg: ansi(0),
    };
}

fn theme_nord() -> Theme {
    return Theme {
        fg: rgb(216, 222, 233),
        bg: rgb(46, 52, 64),
        dim: rgb(129, 138, 158),
        accent: rgb(136, 192, 208),
        border: rgb(76, 86, 106),
        border_focus: rgb(136, 192, 208),
        sel_fg: rgb(46, 52, 64),
        sel_bg: rgb(136, 192, 208),
        title: rgb(236, 239, 244),
        ok: rgb(163, 190, 140),
        warn: rgb(235, 203, 139),
        err: rgb(191, 97, 106),
        panel_bg: rgb(59, 66, 82),
    };
}

// --- ready-made styles ------------------------------------------------------

fn th_text(t: Theme) -> Style { return style(t.fg, t.bg); }
fn th_dim(t: Theme) -> Style { return style(t.dim, t.bg); }
fn th_panel(t: Theme) -> Style { return style(t.fg, t.panel_bg); }
fn th_selected(t: Theme) -> Style { return style(t.sel_fg, t.sel_bg); }
fn th_border(t: Theme) -> Style { return style(t.border, t.bg); }
fn th_border_focus(t: Theme) -> Style { return style(t.border_focus, t.bg); }
fn th_title(t: Theme) -> Style { return style(t.title, t.bg).bold(); }
fn th_ok(t: Theme) -> Style { return style(t.ok, t.bg); }
fn th_warn(t: Theme) -> Style { return style(t.warn, t.bg); }
fn th_err(t: Theme) -> Style { return style(t.err, t.bg); }
fn th_key(t: Theme) -> Style { return style(t.accent, t.bg).bold(); }
