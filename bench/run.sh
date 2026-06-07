#!/bin/bash
# Wyve vs Zig. Both sides: native CPU, full optimization, same driver.
set -e
cd "$(dirname "$0")/.."
mkdir -p build/bench

for k in saxpy reduce stencil; do
  racket -l wyve/cli -- build examples/$k.wyv -o build/bench/$k.ll
  clang -O2 -march=native -Wno-override-module -c build/bench/$k.ll -o build/bench/$k.o
done

zig build-obj -O ReleaseFast -fllvm -femit-bin=build/bench/zig_kernels.o bench/zig_kernels.zig

clang -O2 -march=native bench/driver.c build/bench/*.o -o build/bench/bench
exec build/bench/bench
