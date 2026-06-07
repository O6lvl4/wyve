<!-- description: Complete the @fp contract family — contract (FMA), nsz, arcp, afn, nnan/ninf -->
<!-- done: 2026-06-08 --># @fp flags family

`@fp(reassoc)` exists; the rest of LLVM's fast-math surface should be
individually grantable, per kernel, as contracts:

- `@fp(contract)` — allow fmul+fadd fusion into FMA. **~2× peak on
  matmul.** Today wyvec emits plain ops, which is also why the
  `@interchange` exactness assert holds bitwise; granting `contract`
  trades that exactness explicitly. talk should say so.
- `nsz`, `arcp`, `afn`, `nnan`, `ninf` — each one line in the parser,
  one flag in codegen's `arith`, one transcript line.
- `@fp(fast)` deliberately does NOT exist: bundles are how -ffast-math
  ruined fp hygiene. Wyve grants one permission at a time.

## Done

All seven flags (`reassoc contract nsz arcp afn nnan ninf`) parse,
validate, emit as fast-math flags on float arithmetic, and appear in
the talk transcript. `@fp(contract)` ships on Full_matmul; `@fp(fast)`
deliberately does not exist.
