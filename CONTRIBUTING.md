# Contributing to goose-tui

Thanks for looking. This is a small framework with a deliberately small
surface, and most of its value is in the rules below staying true: if a change
bends one of them, it needs an argument in the pull request, not just code.

## Getting set up

1. Install [Goose](https://github.com/aardappel/goose/releases) (v2026.3 or
   later) and put its directory on `PATH`.
2. Make sure a C compiler is available (`goose toolchain` reports which).
3. Run the suite once before changing anything:

   ```sh
   sh tests/run.sh
   ```

   `--quick` skips the example builds and the pty test. The full run needs
   `sh` and `python3`.

4. Run an example interactively:

   ```sh
   goose run examples/05_todo.goose
   goose run examples/05_todo.goose -- --keys "jjx" --dump
   ```

## Where things live

| file | what belongs there |
|---|---|
| `tui.goose` | terminal, `App`, the run loop, the headless driver |
| `cell.goose` | `Cell`, `Style`, `Canvas`, drawing, the diffing presenter |
| `rect.goose` | rectangle arithmetic only |
| `utf8.goose` | decoding, code-point walking, display width |
| `keys.goose` | `Key`/`Event` and the byte-stream decoder |
| `theme.goose` | the `Theme` struct and the shipped themes |
| `widgets.goose` | every widget and its key handler |
| `src/term.c` | the only platform code |
| `docs/DESIGN.md` | why the choices are what they are |
| `docs/guide.md` | how to use it, in order |
| `docs/reference.md` | the public names, exhaustively |
| `docs/platforms.md` | which hosts and terminals are supported |

## The rules a change has to keep

These are the framework's contract, not style preferences. Each is tested.

1. **An idle frame writes 0 bytes.** `tests/diff.goose` asserts it. A change
   that makes the presenter emit a cursor move or a style reset per frame is a
   regression, even if the screen looks right.
2. **One write per frame.** Escapes must never interleave with `print`, so
   everything goes through `tui_write`.
3. **The C boundary stays six functions.** No allocator, handle, callback or
   pointer may cross it. If a feature seems to need a seventh `extern fn`,
   write the reason in the issue first.
4. **Display width stays in `utf8.goose`.** Do not call `wcwidth`: it answers
   in the process locale, which may be `C`.
5. **No third-party dependencies.** The package is Goose plus libc. A
   dependency has to be worth the deployment story it costs; assume the answer
   is no unless the pull request shows otherwise.
6. **Every supported host is in `docs/platforms.md`.** Do not claim a platform
   works without a test or a stated reason.

## Adding or changing a widget

A widget is three things, and a pull request that adds only the first is
incomplete:

1. the drawing function in `widgets.goose` (and its key handler, if it takes
   input);
2. a golden test in `tests/widgets.goose` (draw into a canvas, compare
   `tui::screen_text`) and, if it computes something, assertions in
   `tests/units.goose`;
3. an entry in `docs/reference.md`, and a line in the gallery
   (`examples/04_widgets.goose`) or a new example when it deserves one.

Widgets that keep state take a small struct by reference (`ListState`,
`InputState`); widgets that only draw take a `Rect` and a `Style`. Do not add
global state: globals in Goose are copied per thread and hidden from the
reader.

## Style

- 80 columns, two-space indent, `//` comments that say *why*, not *what*.
- Top-level declarations are the public API: Goose has no namespace privacy,
  so anything not meant to be called is a candidate for being removed rather
  than hidden. If it must stay, say so in a comment.
- There is no formatter. Match the surrounding code.
- British spelling in prose ("colour", "centred"), matching the existing docs.

## Tests

- `sh tests/run.sh` must pass; CI runs the same script on macOS and Linux.
- New behaviour needs an assertion. A test that cannot fail is not a test.
- The pty test (`tests/pty_test.py`) checks the terminal lifecycle; it uses
  fixed waits today, so if it flakes on your machine, say so in the issue
  rather than deleting the check.

## Commits and pull requests

- One idea per commit; the subject line says what changed and why.
- Say which platforms you ran the suite on.
- If the change is visible in the docs, update them in the same pull request.
- By contributing you agree that your work is licensed under the Apache
  License, Version 2.0 (see `LICENSE`).

## Reporting a bug

Include what the framework cannot guess: OS and version, terminal and `TERM`,
whether you were inside tmux/ssh, the Goose version (`goose version`), and the
smallest program that shows it. A `--dump` frame or the escape bytes are worth
more than a screenshot.
