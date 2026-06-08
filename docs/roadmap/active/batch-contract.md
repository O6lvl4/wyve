<!-- description: @batch — write one signal naively, wyvec lays it out signal-major and widens every op to the lanes -->
# @batch

The data-parallel contract, completing the family
(@interchange/@tile/@parallel/@vectorize). Write one signal's kernel
naively; `@batch(8)` makes wyvec lay the data out signal-major and widen
every scalar op to a float8 across 8 signals — turning a shuffle-bound
single transform into shuffle-free lane-parallel work.

Proven by hand: examples/fft-batch.wyv (a 4-point FFT batched over 8
signals) runs at 1.17 ns/transform — ~9x over the single-signal @simd FFT
(10.7, shuffle-bound) and scalar (10.5), zero shuffles, exact
(bench/NOTES.md). That is the target output; @batch automates the layout
and widening from a naive one-signal kernel.

Stages: (1) hand-written batch — done. (2) @batch widens a straight-line
kernel. (3) @batch from a naive looping kernel with auto signal-major
transpose at the boundary.
