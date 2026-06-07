<!-- description: @tile — first scheduling transform above LLVM, legality proven (WVN020-023), float-exact -->
<!-- done: 2026-06-07 -->
# @tile

Strip-mine + interchange on the proven AST; nested loops landed with
it. Conservative legality: perfect 0..bound nest, write-only arrays,
injective row-major stores, no carried scalars. Honest numbers: i/j
tiling alone paid ~1.05x (b-tile overflows L2) — which named the next
move. (54739ed)
