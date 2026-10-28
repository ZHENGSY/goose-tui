# Changelog

All notable changes to goose-tui are recorded here.

The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Before 1.0 the minor version may break the API; a patch release does not.

## [Unreleased]

### Added

- A release workflow: a `v*` tag builds the demo programs with
  `goose build --standalone` on macOS and Linux, smoke-tests them, and attaches
  the archives and their SHA-256 sums to the GitHub release. Release notes come
  from this file.

## [0.1.0] - 2026-10-28

First release. The API is expected to move before 1.0.

### Added

- Terminal lifecycle: raw mode, alternate screen, hidden cursor, autowrap
  off, mouse opt-in, restore on exit, signals and panic. Six `extern fn`s over
  `src/term.c`; everything above them is Goose.
- A cell canvas with a damage-diff presenter: an idle frame writes 0 bytes,
  and an unchanged caret is not redrawn.
- Wide glyphs (`中` claims two cells, the tail is a marker, overwriting either
  half repairs both) and combining marks.
- An event decoder for CSI/SS3 keys, modifiers, `CSI u`, SGR mouse, bracketed
  paste (chunked) and resize, with a lone `ESC` resolved by a 25 ms timeout.
- Immediate-mode widgets: `panel`, `para`, `ellipsis`, `list`, `table`,
  `tabs`, `input`, `gauge`, `spark`, `scrollbar`, `log_view`, `status`,
  `help`, `focus`, plus the drawing primitives they are built from.
- Rectangle arithmetic: `split_h`, `split_v`, `split_w`, `inset`, `centre`,
  rows and columns.
- Four themes (`dark`, `light`, `mono`, `nord`) as flat structs.
- Headless testing: `tui::screen_text`, `tui::present` and `tui::headless`.
- Seven runnable examples, each with `--dump`, `--keys` and `--frames`.
- Four Goose test suites (260 assertions) and a pty test (17 checks).

### Known limits

- POSIX only: macOS and Linux. A Windows backend does not exist; see
  [`docs/platforms.md`](docs/platforms.md).
- No terminfo and no capability probing; the ANSI/xterm subset is emitted
  unconditionally, with colours degrading in the terminal.
- Bracketed paste is decoded but not enabled by the framework.
