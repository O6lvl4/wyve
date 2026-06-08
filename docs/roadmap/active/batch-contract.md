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
scalar kernel — **done** (examples/batch.wyv: scalar 4-point FFT + @batch(8)
auto-widens to the zero-shuffle float8 IR, 1.16 ns/transform, verified exact;
WVN060 refuses loops/if/calls). (3a) @batch over a block loop — **done** (examples/batch.wyv Blocks: one
call sweeps N=8*blocks signals, body widened with a per-block offset; 1.29
ns/transform on 32768 signals, 2.3x over scalar, zero shuffles). (3b) AoS input with an auto signal-major transpose at the boundary —
**measured and rejected** for this workload: the 8x8 transpose
(examples/transpose.wyv t8) costs 48 shuffles round-trip and sinks a
batched 4-point FFT to 3.67 ns/transform, below scalar (2.96) and far below
block-SoA 3a (1.29). @batch keeps the SoA layout. 3b stays conditional —
worth revisiting only for a kernel whose compute dwarfs the transpose.
