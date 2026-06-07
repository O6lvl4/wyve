<!-- description: #lang wyve, talk/run, REPL with retractable contracts — the conversation with LLVM -->
<!-- done: 2026-06-07 -->
# Conversation layer

A .wyv file is a runnable Racket program (custom reader). `run` =
verify → talk (remark YAML translated to contract vocabulary, honored /
DISAGREEMENT verdicts) → execute via generated C driver. REPL:
(ask #:without-noalias '("x") #:force #t) — wyvec refuses unproven
claims unless overruled, and marks forced sends UNPROVEN. (ac3d1ab)
