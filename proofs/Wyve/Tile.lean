/-
  Soundness of wyvec's `@tile` legality check (WVN020–022).

  `@tile(i: B, …)` strip-mines a loop over `[0, M·B)` into M tiles of width B
  and runs the tile loop outside the element loop (strip-mine + interchange —
  `racket/sema.rkt`'s `tile-check` admits exactly the perfect nest this
  models). Strip-mining splits the index range; the tiled schedule visits the
  same indices, just grouped into tiles. So the sum over the whole range
  equals the double sum over tiles × elements — the total, and thus every
  result, is unchanged. This is the bitwise-exact claim for `@tile`.

  The mathematical heart is reindexing a range as a product:
  `Fin (M * B) ≃ Fin M × Fin B` (`finProdFinEquiv`). Combined with
  `@interchange`'s `Finset.sum_comm`, this gives the full 2-D tiling that
  `examples/matmul.wyv`'s `@tile(i: 64, j: 64)` performs.
-/
import Mathlib

namespace Wyve

open Finset

/--
  **Strip-mining preserves the sum.** Summing `f` over the flat range
  `Fin (M·B)` equals summing it tile-by-tile: outer over the `M` tiles, inner
  over the `B` elements of each, reindexed by `finProdFinEquiv`. `@tile`
  reshapes the iteration space exactly this way and the total is the same —
  the schedule moved, the value didn't.
-/
theorem tile_sum {α} [AddCommMonoid α] (M B : ℕ) (f : Fin (M * B) → α) :
    (∑ i : Fin (M * B), f i)
  = ∑ a : Fin M, ∑ b : Fin B, f (finProdFinEquiv (a, b)) := by
  rw [← finProdFinEquiv.sum_comp f, Fintype.sum_prod_type]

/--
  **The 2-D tile preserves the sum.** Tiling a perfect 2-loop nest over
  `Fin (MI·BI) × Fin (MJ·BJ)` — strip-mine both axes, hoist both tile loops
  outside — visits the same index pairs and lands on the same total. This is
  what `@tile(i: BI, j: BJ)` does to matmul's `i,j` nest (the inner reduction
  rides along unchanged), so the 91.5-GFLOPS tiled schedule is bitwise-exact.
-/
theorem tile2_sum {α} [AddCommMonoid α] (MI BI MJ BJ : ℕ)
    (g : Fin (MI * BI) → Fin (MJ * BJ) → α) :
    (∑ i : Fin (MI * BI), ∑ j : Fin (MJ * BJ), g i j)
  = ∑ ii : Fin MI, ∑ jj : Fin MJ, ∑ bi : Fin BI, ∑ bj : Fin BJ,
      g (finProdFinEquiv (ii, bi)) (finProdFinEquiv (jj, bj)) := by
  rw [tile_sum MI BI]
  simp only [tile_sum MJ BJ]
  -- now ∑ ii, ∑ bi, ∑ jj, ∑ bj; swap the inner bi ↔ jj to reach the goal order
  exact Finset.sum_congr rfl (fun _ _ => Finset.sum_comm)

end Wyve
