<!-- description: Prove @noalias at call boundaries — ownership analysis, the last trusted claim -->
# Stage 2 — ownership

Everything else is checked; @noalias is still trusted at the ABI
boundary. Ownership/borrow rules for callers (or a checked-caller
story via the C-driver/host bindings) close the loop on "proven, not
promised".

## Done (call-boundary @noalias)

WVN050 proves the callee's @noalias at every call site: an argument bound
to a @noalias parameter must itself be @noalias in the caller (so it
cannot alias the others), and no pointer may reach two @noalias
parameters (it would alias itself). In-place calls to a @noalias kernel
are compile errors, not silent UB — examples/invalid/alias-call.wyv is
normative. The outermost caller's @noalias is the calling language's
obligation; Rust's borrow checker discharges it, closing the loop end to
end. Full ownership/borrow inference within a kernel (heap, lifetimes)
remains future work, but the @noalias contract — the one the optimizer
actually relies on — is now proven, not promised.
