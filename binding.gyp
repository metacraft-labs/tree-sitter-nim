{
  "targets": [
    {
      "target_name": "tree_sitter_nim_binding",
      "sources": [
        "bindings/node/binding.cc",
        "src/parser.c",
        "src/scanner.c"
      ],
      "include_dirs": [
        "src",
        "<!@(node -p \"require('node-addon-api').include\")"
      ],
      "cflags_c": ["-std=c11"],
      "cflags_cc": ["-std=c++17"],
      "defines": ["_CRT_SECURE_NO_WARNINGS", "NAPI_DISABLE_CPP_EXCEPTIONS"]
    }
  ]
}
