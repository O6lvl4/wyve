<!-- description: @vectorize(width/interleave/predicate/scalable/disable) + @unroll, all remark-verified -->
<!-- done: 2026-06-07 -->
# Optimizer knobs as verified contracts

Numeric knobs are verified against LLVM's reply: demand interleave 4
and get 2, the build fails. loop-unroll remarks collected too — LLVM
volunteers what it did on its own. REPL knob sweeps:
(ask #:width 4 #:interleave 8). (129c6fe)
