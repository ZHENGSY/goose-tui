#!/bin/sh
# tests/run.sh -- everything, in the order that fails fastest.
#
#   1. the Goose typecheck (the package, through its entry file); 2. the Goose
#   unit tests (rects, cells, UTF-8, decoder, widgets, diff); 3. every example,
#   headless, so a broken sample is caught before a human opens it; 4. one
#   example on a real pty: alternate screen, deltas, resize, restore.
#
#   sh tests/run.sh            # all of it
#   sh tests/run.sh --quick    # skip the pty and the example builds
#
# Every step checks the exit status of the command it runs. A suite that fails
# to compile prints no line, and a filtered pipeline would hide that; that is
# why the output is captured and the status tested instead.

set -eu
cd "$(dirname "$0")/.."

quick=0
if [ "${1:-}" = "--quick" ]; then quick=1; fi

fail() { echo "FAIL  $*"; exit 1; }

echo "== typecheck =="
# The modules are one package: check it through the entry file. Checking a
# single module alone reports its siblings' names as unknown, because a
# non-root file does not carry the rest of the package.
out=$(goose check tui.goose 2>&1) || { printf '%s\n' "$out"; fail "typecheck tui.goose"; }
printf '%s\n' "$out" | grep -i 'warning' || true

echo "== unit tests =="
for t in units decoder widgets diff; do
    printf '%-10s ' "$t"
    out=$(goose run "tests/$t.goose" 2>/dev/null) || fail "$t did not run"
    line=$(printf '%s\n' "$out" | grep "passed," | tail -1)
    [ -n "$line" ] || fail "$t printed no result line"
    printf '%s\n' "$line"
done

if [ "$quick" = 1 ]; then
    echo "ok (quick)"
    exit 0
fi

echo "== examples, headless =="
for f in examples/*.goose; do
    case "$f" in examples/_*) continue ;; esac
    name=$(basename "$f" .goose)
    out=$(goose run "$f" -- --dump --cols 80 --rows 24 2>/dev/null) || fail "$name did not run"
    lines=$(printf '%s' "$out" | wc -l | tr -d ' ')
    if [ "$lines" -lt 2 ]; then
        fail "$name drew $lines lines"
    fi
    printf '%-14s %s lines\n' "$name" "$lines"
done

echo "== pty =="
goose build examples/05_todo.goose >/dev/null 2>&1 || fail "build 05_todo"
python3 tests/pty_test.py ./examples/05_todo

echo "ok"
