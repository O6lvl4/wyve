<!-- description: GitHub Actions — enforce the normative examples publicly -->
# CI

GitHub Actions: install Racket + clang, `raco pkg install --link`,
run `racket racket/tests.rkt`. The examples/ directory is normative;
CI is what makes that claim public. Bench is NOT in CI (numbers are
machine-specific); compile-and-reject tests are.
