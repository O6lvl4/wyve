<!-- description: wyvec tune — schedule search; beat LLVM's cost model 1.42x on the reduction -->
<!-- done: 2026-06-07 -->
# Schedule search (tune)

Sweeps width x interleave + "LLVM chooses", verifies each variant
against remarks, measures, suggests the winning contract. Found
vf16/ic4 on the reduction — 1.42x over both the written contract and
LLVM's own cost model; pinned back into examples/reduce.wyv. (645e606)
