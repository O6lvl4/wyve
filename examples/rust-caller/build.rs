// Compile the Wyve kernels and link them in. Contract violations in the
// .wyv file fail the *Rust* build, with WVN diagnostics.
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let out = std::env::var("OUT_DIR").unwrap();
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let kernel = manifest.join("../matmul.wyv");

    let ll = format!("{out}/matmul.ll");
    let obj = format!("{out}/matmul.o");

    let status = Command::new("racket")
        .args(["-l", "wyve/cli", "--", "build"])
        .arg(&kernel)
        .args(["-o", &ll])
        .status()
        .expect("wyvec (racket) not found — kernel authors need it; consumers can vendor the .ll");
    assert!(status.success(), "wyvec rejected the kernel contracts");

    let status = Command::new("clang")
        .args(["-O2", "-march=native", "-Wno-override-module", "-c", &ll, "-o", &obj])
        .status()
        .expect("clang not found");
    assert!(status.success(), "clang rejected the IR");

    println!("cargo:rustc-link-arg={obj}");
    println!("cargo:rerun-if-changed={}", kernel.display());
}
