//! The examples directory is normative: everything in examples/ must
//! compile, everything in examples/invalid/ must be rejected with the
//! diagnostic its header documents.

use std::process::Command;

fn wyvec(args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_wyvec")).args(args).output().expect("failed to run wyvec")
}

#[test]
fn valid_examples_compile_with_contracts_in_ir() {
    for name in ["saxpy", "reduce", "stencil"] {
        let out = wyvec(&["build", &format!("examples/{name}.wyv")]);
        assert!(
            out.status.success(),
            "{name} failed:\n{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let ir = String::from_utf8_lossy(&out.stdout);
        assert!(ir.contains("noalias"), "{name}: missing noalias attribute");
        assert!(ir.contains("llvm.loop.vectorize.enable"), "{name}: missing vectorize metadata");
        assert!(ir.contains("llvm.loop.vectorize.width\", i32 8"), "{name}: missing width 8");
    }
}

#[test]
fn effect_contract_becomes_param_attributes() {
    let out = wyvec(&["build", "examples/saxpy.wyv"]);
    let ir = String::from_utf8_lossy(&out.stdout);
    assert!(ir.contains("readonly %x"), "x should be readonly (reads only)");
    assert!(!ir.contains("readonly %y"), "y is read+write, must not be readonly");
}

#[test]
fn reduce_grants_reassoc() {
    let out = wyvec(&["build", "examples/reduce.wyv"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let ir = String::from_utf8_lossy(&out.stdout);
    assert!(ir.contains("fadd reassoc"), "reassoc flag missing on float add:\n{ir}");
}

#[test]
fn dependence_is_rejected() {
    let out = wyvec(&["check", "examples/invalid/dependence.wyv"]);
    assert!(!out.status.success(), "dependence.wyv must not compile");
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("WVN014"), "expected WVN014, got:\n{err}");
    assert!(err.contains("previous iteration"), "expected canonical message, got:\n{err}");
}

#[test]
fn effect_violation_is_rejected() {
    let out = wyvec(&["check", "examples/invalid/effect-violation.wyv"]);
    assert!(!out.status.success(), "effect-violation.wyv must not compile");
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("WVN003"), "expected WVN003, got:\n{err}");
    assert!(err.contains("declares only reads(src)"), "expected canonical message, got:\n{err}");
}
