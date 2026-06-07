<!-- description: GitHub Actions — enforce the normative examples publicly -->
<!-- done: 2026-06-08 --># CI

GitHub Actions: install Racket + clang, `raco pkg install --link`,
run `racket racket/tests.rkt`. The examples/ directory is normative;
CI is what makes that claim public. Bench is NOT in CI (numbers are
machine-specific); compile-and-reject tests are.

## Done

ci.yml: normative examples on ubuntu/macos for every push/PR — first
run green in 45s. release.yml: every v* tag builds standalone wyvec on
a 4-platform matrix (x86_64/arm64 x linux/darwin) and attaches the
tarballs to the GitHub release.
