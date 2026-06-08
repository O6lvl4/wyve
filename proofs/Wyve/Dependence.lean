/-
  Soundness of wyvec's loop-carried dependence analysis (WVN014).

  In `racket/sema.rkt`, `@vectorize(require)` is accepted only when, for each
  array, every access subscript is the affine form `i + c` (a constant offset
  from the induction variable) and the constants line up so the analysis sees
  no conflict. This file models that analysis over `Int` offsets and proves
  the two claims wyvec relies on:

    1. SOUNDNESS of acceptance — when an array's accesses all share one
       offset, no two distinct iterations ever touch the same location, so
       there is no loop-carried dependence. Vectorizing is safe.

    2. NECESSITY of rejection — when a read offset is strictly below a write
       offset (`cr < cw`), a genuine earlier-iteration write does collide
       with a later read. wyvec is right to refuse: the "reads … written in
       the previous iteration" diagnostic names a real dependence.

  `omega` discharges each goal — these are decidable facts about integer
  affine indexing, exactly the fragment wyvec's analysis lives in.
-/

namespace Wyve

/-- An access touches element `i + c` on iteration `i`. -/
def loc (c i : Int) : Int := i + c

/--
  **Acceptance is sound.** If two accesses share the same offset `c`, then
  they collide only within a single iteration: `loc c i = loc c j → i = j`.
  No distinct iterations alias, so there is no loop-carried dependence and
  vectorization preserves meaning.
-/
theorem accept_sound (c i j : Int) :
    loc c i = loc c j → i = j := by
  unfold loc; omega

/--
  Generalization: even with two *different* arrays-of-the-same-offset, a
  write on iteration `i` and a read on iteration `j` at a shared offset
  collide only when `i = j`. (Cross-iteration safety for the whole accepted
  set, since the analysis admits only a single offset per array.)
-/
theorem no_carried_dep (c i j : Int) (hne : i ≠ j) :
    loc c i ≠ loc c j := by
  unfold loc; omega

/--
  **Rejection is necessary.** If a read offset `cr` is strictly less than a
  write offset `cw`, there really is a loop-carried dependence: pick the
  write iteration to be the read iteration minus `(cw - cr)`, an *earlier*
  iteration whose write lands exactly where the later read looks. This is
  the `x[i] reads x[i-1] written in the previous iteration` case — WVN014 is
  not being conservative, it is reporting a true hazard.
-/
theorem reject_necessary (cw cr : Int) (h : cr < cw) :
    ∃ iw ir : Int, iw < ir ∧ loc cw iw = loc cr ir := by
  refine ⟨cr, cw, by omega, ?_⟩
  unfold loc; omega

/--
  The exact boundary the analysis decides on: a read at offset `cr` and a
  write at offset `cw` admit a loop-carried dependence **iff** the offsets
  differ. Equal offsets ⇒ safe (accept); unequal ⇒ a hazard exists at some
  pair of distinct iterations (reject). This is precisely wyvec's rule.
-/
theorem dep_iff_offsets_differ (cw cr : Int) :
    (∃ iw ir : Int, iw ≠ ir ∧ loc cw iw = loc cr ir) ↔ cw ≠ cr := by
  constructor
  · rintro ⟨iw, ir, hne, hloc⟩
    unfold loc at hloc; omega
  · intro hne
    exact ⟨cr, cw, by omega, by unfold loc; omega⟩

end Wyve
