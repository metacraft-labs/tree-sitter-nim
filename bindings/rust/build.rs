fn main() {
    let mut build = cc::Build::new();
    build
        .include("../../src")
        .file("../../src/parser.c")
        .file("../../src/scanner.c")
        .flag_if_supported("-std=c11");

    build.compile("tree-sitter-nim");

    println!("cargo:rerun-if-changed=../../grammar.js");
    println!("cargo:rerun-if-changed=../../src/scanner.c");
    println!("cargo:rerun-if-changed=../../src/parser.c");
}
