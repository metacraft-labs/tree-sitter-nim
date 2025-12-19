{
  description = "Tree-sitter grammar for the Nim programming language";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem = { config, self', inputs', pkgs, system, ... }: {
        devShells.default = pkgs.mkShell {
          name = "tree-sitter-nim-dev";

          buildInputs = with pkgs; [
            # Node.js for the Node bindings and dev workflow
            nodejs_20

            # tree-sitter CLI
            tree-sitter

            # For building native Node modules
            python3

            # Rust toolchain for the Rust bindings
            rustc
            cargo
            rustfmt
            clippy

          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            # C compiler for Linux
            pkgs.gcc
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            # libiconv needed for tree-sitter on macOS
            pkgs.libiconv
          ];

          shellHook = ''
            echo "tree-sitter-nim development environment"
            echo ""
            echo "Available commands:"
            echo "  npm install      - Install Node dependencies"
            echo "  npm run generate - Generate parser from grammar.js"
            echo "  npm test         - Run tree-sitter tests"
            echo "  npm run build    - Build Node native module"
            echo ""
            echo "Rust bindings (from bindings/rust):"
            echo "  cargo test       - Run Rust tests"
            echo ""
          '';
        };

        packages = {
          default = pkgs.tree-sitter.buildGrammar {
            language = "nim";
            version = "0.1.0";
            src = ./.;
          };
        };
      };
    };
}
