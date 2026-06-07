#!/bin/bash
# Build a standalone wyvec — no Racket needed on the target machine.
#   scripts/make-dist.sh            -> dist/wyvec-<os>-<arch>/bin/wyvec
# Requires: racket + `raco pkg install compiler-lib` (author machine only).
set -euo pipefail
cd "$(dirname "$0")/.."

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
out="dist/wyvec-${os}-${arch}"

rm -rf dist/wyvec.tmp "$out"
mkdir -p dist
raco exe -o dist/wyvec.tmp racket/cli.rkt
chmod u+w dist/wyvec.tmp   # raco exe emits r-x; distribute must patch the copy
raco distribute "$out" dist/wyvec.tmp
rm dist/wyvec.tmp
mv "$out/bin/wyvec.tmp" "$out/bin/wyvec" 2>/dev/null || true

echo "standalone wyvec: $out/bin/wyvec ($(du -sh "$out" | cut -f1))"
"$out/bin/wyvec" check examples/saxpy.wyv
