# Strategy — the fork after the BLAS wall

This is the strategic crossroads Wyve reached after measuring itself against
the real world (an Almide adoption PoC, June 2026). It records the choice,
the evidence that forced it, and the recommendation — so the direction
survives the conversation that produced it.

## What the measurements established

A PoC putting Wyve under Almide's numeric runtime measured three contests
(examples/almide-poc, bench/diff.c):

| contest | result |
|---|---|
| native matmul vs Accelerate sgemm | **lose 2.7–3.8×** |
| native fused linear+gelu vs Accelerate+gelu | **lose 4.5–14×** |
| WASM saxpy vs the compiler's autovectorizer | **win 1.55×** |

And the diagnosis of *why* native loses: on x86 both Wyve and Accelerate
emit the same AVX2 FMA (`vfmadd213ps`). The gap is **not the instruction
set** — it is the micro-kernel: Accelerate has hand-written register
blocking + packing; Wyve's `@tile` only does the outer tiling and leaves the
innermost kernel to LLVM. (On Apple Silicon a second wall is added: AMX, a
non-public matrix coprocessor only Apple's libraries can reach — LLVM can't
emit it at all.)

LLVM's relationship to Accelerate is just **a library call**: LLVM compiles
`cblas_sgemm(...)`, the linker binds Apple's prebuilt dylib. A general
compiler's auto-optimizer doesn't reach a hand-tuned GEMM kernel — which is
why the world runs "LLVM-compiled code + a BLAS call," and why Wyve hit the
same wall.

The corollary that matters: **where there is no BLAS — WASM, embedded — the
wall is gone**, and Wyve's explicit-contract SIMD beats the autovectorizer.

## The first fork: speed, or verification?

| | **A: win on speed** | **B: win on verification** |
|---|---|---|
| goal | kernels faster than the incumbent | *proof* that optimization doesn't change results |
| speed is | the point | enough if it matches naive |
| banner | "contract = fastest schedule" | "proven, not promised" |
| fit with Wyve's soul | medium | **highest** |

The single brightest result of Wyve's whole arc was not 86× or 9× — it was
the risk review showing `@tile`/`@interchange`/`@parallel` are
**bitwise-exact** vs naive, and only `@fp(contract)` moves a result, by
contract. No other language claims that. Wyve's soul is B.

## If A (speed) — which arena, against whom?

| arena | opponent | odds | value | effort | crux |
|---|---|---|---|---|---|
| **A1 native GEMM** | Accelerate / BLAS | low–med | high | **large** | lift register tiling + packing into a contract (schedule-composition). Same AVX instructions, so not impossible — but BLAS is decades of hand-tuning |
| **A2 WASM / embedded** | the autovectorizer | **high (proven)** | medium | medium | the arena with no BLAS. saxpy 1.55× already. Needs per-target lowering (usize → i32 on wasm32) |
| **A3 quantized matmul** | Almide's hand loop | medium | med–high | medium | BLAS structurally can't; win by fusing dequant+matmul. But memory-bound risk |

## If B (verification)

Extend the Lean soundness proofs (WVN020–025), widen contract coverage,
build regression tooling: a language that **proves optimization changed
nothing**. The adoption motive is not speed but the *impossibility of
regression* — CI that guarantees a schedule change is bit-for-bit safe.

## Three strategy packages

- **① The researcher's bet (A1-centered)** — lift register tiling into a
  contract and challenge BLAS on native. Win → "contract-level BLAS," the
  strongest possible proof of the thesis. Lose → "so close." High risk, high
  reward, large effort. *Not Wyve's home ground — it wasn't born to brawl
  with BLAS.*
- **② Pragmatism (A2 + A3)** — target where BLAS is absent or inapplicable
  (WASM, embedded, quantized). Wins are reliable but the market is a niche.
  Low risk, sure reward. Directly serves Almide-on-WASM adoption.
- **③ Purification (B-centered)** — leave the speed race, perfect "proven,
  not promised." Truest to Wyve's soul. Requires re-stating the adoption
  motive (the answer to "why, if it isn't faster").

## Recommendation

**② as the practical footing + ③ as the banner.** Win for real where Wyve
can (WASM/embedded, BLAS-free), and sharpen the one claim no other language
can make (verified bitwise-exact optimization). ① is a fascinating research
challenge but not the main line — Wyve wasn't created to out-tune Accelerate;
it was created so an optimization is a proven contract, not a prayer. The *why* beneath this fork is [the philosophy](../PHILOSOPHY.md): Wyve is the rider, not the dragon.

Concretely, the next steps under ②+③:
- ② per-target lowering (usize i32 on wasm32), then a WASM matmul on
  inference shapes — the contest on the backend where Wyve wins.
- ③ extend Lean to the scheduling transforms (WVN020–025), so "bitwise-exact"
  is proven all the way down, not just demonstrated.

---

**Update — the direction converged on [Wyve v2 — Almide-native](active/v2-almide-native.md).**
Keep the proven/Lean/codegen assets; drop the standalone-language stance;
become Almide's verified scheduler over the data-movement hierarchy
(algorithm/schedule split, memory hierarchy first-class, contracts derived
from Almide's semantics). Halide/Exo/MLIR already do the pieces — the one
place v2+Almide stands alone is deriving the loops *and the contracts* from
meaning, then proving the schedule.
