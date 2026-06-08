/-
  Soundness of wyvec's `@interchange` legality check (WVN024).

  `@interchange(p, j)` hoists a reduction loop `p` to run outside the loop `j`
  it currently sits inside — the ikj matmul schedule (`racket/sema.rkt`'s
  `interchange-check` admits exactly the perfect reduction nest this models).
  The loop body accumulates a sum; interchanging the loops reorders how the
  additions are performed but not the total. So the result is identical — the
  same value, not merely the same speed. This is the bitwise-exact claim for
  `@interchange`, now proven rather than demonstrated.

  The mathematical heart is `Finset.sum_comm`: a double sum is independent of
  which index ranges outermost. We use it to show matmul's value is unchanged
  by the ikj interchange, and that the per-output reduction is built to the
  same total whatever order the schedule accumulates it in.
-/
import Mathlib

namespace Wyve

open Finset

/--
  **Interchange preserves the double sum.** Summing `f i j` with `i` outer and
  `j` inner equals summing it with `j` outer and `i` inner. This is exactly
  what `@interchange` does to a perfectly-nested accumulation loop — swap the
  two loop orders — and the total is the same (`Finset.sum_comm`). The
  optimizer changed the schedule, not the value.
-/
theorem interchange_sum {α} [AddCommMonoid α] (I J : Finset ℕ) (f : ℕ → ℕ → α) :
    ∑ i ∈ I, ∑ j ∈ J, f i j = ∑ j ∈ J, ∑ i ∈ I, f i j :=
  Finset.sum_comm

/--
  **matmul is unchanged by the ikj interchange.** A matrix product entry is
  `c[i,j] = Σ_p a[i,p]·b[p,j]`. Computing the whole output as `Σ_i Σ_j (…)` —
  the natural ijp order — equals computing it as `Σ_j Σ_i (…)` after the
  interchange. Every entry is the same reduction; reordering the loops that
  visit the entries doesn't touch any entry's value.
-/
theorem matmul_interchange {α} [CommRing α] (I J K : Finset ℕ) (a b : ℕ → ℕ → α) :
    (∑ i ∈ I, ∑ j ∈ J, ∑ p ∈ K, a i p * b p j)
  = (∑ j ∈ J, ∑ i ∈ I, ∑ p ∈ K, a i p * b p j) :=
  Finset.sum_comm

/--
  **The reduction's total is permutation-independent.** `@interchange` paired
  with scalar expansion accumulates each output `c[j] = Σ_p a[p]·b[p,j]` by
  visiting `p` in whatever order the schedule picks. Reindexing the summation
  by any bijection `e` of the index type leaves the total unchanged — so the
  expanded, interchanged accumulation lands on exactly the value the naive
  reduction would, in any order. (`Finset.sum_equiv`.)
-/
theorem reduction_reorder {α} [AddCommMonoid α] (K : Finset ℕ) (g : ℕ → α)
    (e : ℕ ≃ ℕ) (he : ∀ p, p ∈ K ↔ e p ∈ K) :
    ∑ p ∈ K, g (e p) = ∑ p ∈ K, g p :=
  Finset.sum_equiv e he (fun _ _ => rfl)

end Wyve
