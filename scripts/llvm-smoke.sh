#!/bin/bash
# llvm-smoke.sh — track LLVM by testing, not by hoping.
#
# Wyve's codegen emits LLVM IR, so it inherits a dependency on the LLVM
# toolchain: IR syntax, and — the subtle one — whether intrinsics lower to
# real code. Offline IR-string tests (racket/tests.rkt) can't see this; an
# intrinsic that doesn't lower (llvm.tanh on LLVM 15) only fails at link time.
#
# This smoke test compiles every normative example through the ACTUAL clang
# and checks the object for unlowered @llvm.* intrinsics. When LLVM's behavior
# drifts, this fails loudly instead of shipping a broken kernel. That is how
# the codegen layer tracks LLVM: a regression gate, not a prayer. (The
# verification layer — dependence analysis, schedule legality — is LLVM-
# independent by design and needs no such gate.)
set -u
fail=0
tmp="$(mktemp -d)"
clang --version | head -1
for f in examples/*.wyv; do
  racket -l wyve/cli -- build "$f" -o "$tmp/x.ll" 2>/dev/null || { echo "BUILD FAIL: $f"; fail=1; continue; }
  if ! clang -O2 -Wno-override-module -c "$tmp/x.ll" -o "$tmp/x.o" 2>"$tmp/err"; then
    echo "CLANG FAIL: $f"; head -1 "$tmp/err"; fail=1; continue
  fi
  und="$(nm -u "$tmp/x.o" 2>/dev/null | grep -i 'llvm\.' || true)"
  if [ -n "$und" ]; then echo "UNLOWERED INTRINSIC in $f:"; echo "$und"; fail=1; fi
done
rm -rf "$tmp"
[ "$fail" -eq 0 ] && echo "all examples compile and lower cleanly on this LLVM" || echo "LLVM smoke test FAILED"
exit $fail
