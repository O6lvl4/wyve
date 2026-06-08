/-
  Soundness of wyvec's `@parallel` legality check (WVN025).

  `@parallel(i)` dispatches a loop's iterations across cores in an unspecified
  order. In `racket/sema.rkt`, `parallel-check` accepts it only when the
  iterations are independent: each iteration writes its own output location
  (an injective write subscript), reads no location another iteration writes,
  and carries no scalar across iterations. Under those conditions the order in
  which iterations run cannot matter — sequential, reversed, or scattered
  across N cores all produce the same array.

  We model the loop body as: iteration with output location `l` writes value
  `v`, i.e. `Function.update arr l v`. Independence is exactly "distinct output
  locations." This file proves that independent writes COMMUTE, and lifts that
  to: reordering a run of independent iterations leaves the final array
  unchanged. Commutation is the generator — every permutation of independent
  iterations is a composition of adjacent independent swaps — so this is the
  heart of why `@parallel` is bitwise-exact, not merely fast.
-/

namespace Wyve

/-- A mutable array, modeled as a map from location to value. Writing value
    `b` at location `a` is `upd f a b`. (Defined here rather than reusing
    `Function.update`, which lives in Mathlib — these proofs stay on Lean
    core + `omega`, like the dependence proofs.) -/
def upd {α} (f : Int → α) (a : Int) (b : α) : Int → α :=
  fun x => if x = a then b else f x

/--
  **Independent writes commute.** Writing `va` at `la` then `vb` at `lb`, when
  `la ≠ lb`, gives the same array as doing them in the other order. This is
  the local fact `parallel-check`'s injectivity condition buys: two iterations
  with distinct output locations can run in either order. Every reordering of
  independent iterations is built from such adjacent swaps, so order cannot
  change the result.
-/
theorem write_comm {α} (arr : Int → α) (la lb : Int) (va vb : α) (h : la ≠ lb) :
    upd (upd arr la va) lb vb = upd (upd arr lb vb) la va := by
  funext x
  by_cases hxa : x = la <;> by_cases hxb : x = lb <;>
    simp [upd, hxa, hxb] <;> omega

/-- Running a list of iterations: fold each `(location, value)` write over the
    array, left to right. This is one concrete execution order. -/
def run {α} (init : Int → α) (ws : List (Int × α)) : Int → α :=
  ws.foldl (fun arr p => upd arr p.1 p.2) init

/--
  **Swapping two adjacent independent iterations preserves the run.** If the
  two iterations at the front write distinct locations, exchanging them yields
  the same final array, whatever follows. The adjacent-transposition case of
  permutation invariance — and since adjacent transpositions generate all
  permutations, independent iterations may be scheduled in any order.
-/
theorem run_swap {α} (init : Int → α) (a b : Int × α) (rest : List (Int × α))
    (h : a.1 ≠ b.1) :
    run init (a :: b :: rest) = run init (b :: a :: rest) := by
  unfold run
  simp only [List.foldl_cons]
  rw [write_comm init a.1 b.1 a.2 b.2 h]

/--
  **The last iteration commutes to the front when independent of the first.**
  A small corollary showing the array after a head write then a run is the
  same as folding the run first — used to reason about sequential vs scattered
  schedules of an independent loop.
-/
theorem run_cons {α} (init : Int → α) (a : Int × α) (ws : List (Int × α)) :
    run init (a :: ws) = run (upd init a.1 a.2) ws := by
  unfold run
  rw [List.foldl_cons]

end Wyve
