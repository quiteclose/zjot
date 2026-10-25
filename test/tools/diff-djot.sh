#!/usr/bin/env bash
# Differential check of zjot against djot.js 0.3.2: every test/cli/*.dj and
# test/tools/corpus/*.dj (or the files given as arguments) is run through both in HTML
# and in --ast --sourcepos (djot.js: -t ast -p, rendered by djot2ast.py), and every
# divergence is printed as a unified diff. Exit 1 if any diverged. The deliberate
# differences written in the test/zjot.test header are the only expected output.
# Local only (needs node/npx; CI has none). Run from anywhere after `zig build`.
set -euo pipefail
export npm_config_loglevel=error # keep npx's "notice run" lines out of the diff output
cd "$(dirname "$0")/../.."
zjot=zig-out/bin/zjot
[ -x "$zjot" ] || { echo "$zjot not found: run zig build first" >&2; exit 2; }
files=("$@")
[ ${#files[@]} -gt 0 ] || files=(test/cli/*.dj test/tools/corpus/*.dj)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# A tool that fails (no network for npx, a crash) ends the run with exit 2, so it is never
# read as a divergence.
run() { "${@:2}" > "$tmp/$1" || { echo "diff-djot: failed on $f: ${*:2}" >&2; exit 2; }; }
status=0
for f in "${files[@]}"; do
  run ref.html npx -y @djot/djot@0.3.2 "$f"
  run zjot.html "$zjot" "$f"
  diff -u --label "djot.js $f html" --label "zjot $f html" "$tmp/ref.html" "$tmp/zjot.html" || status=1
  run ref.ast python3 test/tools/djot2ast.py -p < "$f"
  run zjot.ast "$zjot" --ast --sourcepos "$f"
  diff -u --label "djot.js $f ast -p" --label "zjot $f --ast --sourcepos" "$tmp/ref.ast" "$tmp/zjot.ast" || status=1
done
exit $status
