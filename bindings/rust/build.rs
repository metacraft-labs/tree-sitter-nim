use std::path::PathBuf;

fn main() {
    let src_dir: PathBuf = std::env::var("CARGO_MANIFEST_DIR")
        .map(PathBuf::from)
        .expect("CARGO_MANIFEST_DIR not set")
        .join("../../src");

    let mut build = cc::Build::new();
    build
        .include(&src_dir)
        .file(src_dir.join("parser.c"))
        .file(src_dir.join("scanner.c"))
        .flag_if_supported("-std=c11");

    build.compile("tree-sitter-nim");

    println!("cargo:rerun-if-changed={}", src_dir.join("../grammar.js").display());
    println!("cargo:rerun-if-changed={}", src_dir.join("scanner.c").display());
    println!("cargo:rerun-if-changed={}", src_dir.join("parser.c").display());
}
