<!-- description: Call Wyve kernels from Rust — vendored .ll, standalone wyvec, no Racket for consumers -->
<!-- done: 2026-06-08 --># Rust integration

Wyve kernels are C-ABI symbols; Rust calls them via extern "C" + a safe
wrapper whose &[f32]/&mut [f32] signature makes the borrow checker prove
@noalias at the call boundary — stage 2 closes for free on Rust callers.

The Racket dependency is a distribution question, three tiers:

1. **Vendored .ll** (best for consumers): wyvec output is deterministic
   text — commit it like generated bindings. Consumers need only clang;
   Racket is for kernel authors. CI regenerates and diffs.
2. **Standalone wyvec** (done): `scripts/make-dist.sh` → raco
   exe + distribute → 59 MB self-contained binary, verified to run
   without Racket installed. Ship per-platform via GitHub Releases.
3. **Production port** (later): only once the language stops moving;
   the Rust stage-0 lives in history (e396e09). Racket stays the lab.

Remaining: the demo crate (build.rs + safe wrappers + a benchmark
calling Full_matmul from Rust).

## Done

examples/rust-caller: build.rs runs wyvec build + clang -c and links the
object; contract violations fail the cargo build with WVN diagnostics.
Safe wrappers take &[f32]/&mut [f32] — the borrow checker proves the
@noalias call boundary. Measured from Rust: 80 GFLOPS, 68x over naive,
agreement 2e-7 (FMA tolerance). Remaining tiers (vendored .ll policy,
release binaries) tracked above.
