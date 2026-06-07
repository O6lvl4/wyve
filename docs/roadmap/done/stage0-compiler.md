<!-- description: wyvec in Racket — lexer/parser/sema/codegen, Objective-C grammar to textual LLVM IR -->
<!-- done: 2026-06-07 -->
# Stage 0 compiler

Dependency-free pipeline: Obj-C grammar slice → contract verification
(WVN001-016) → textual .ll. First in Rust (e396e09, later removed),
ported to Racket as the primary implementation (ac3d1ab). Byte-stable
IR; mem2reg rebuilds SSA; floats as f64-bit-pattern hex.
