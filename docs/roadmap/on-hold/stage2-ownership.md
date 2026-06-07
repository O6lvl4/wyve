<!-- description: Prove @noalias at call boundaries — ownership analysis, the last trusted claim -->
# Stage 2 — ownership

Everything else is checked; @noalias is still trusted at the ABI
boundary. Ownership/borrow rules for callers (or a checked-caller
story via the C-driver/host bindings) close the loop on "proven, not
promised".
