{
  description = "Tree-sitter grammar for the Nim programming language";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      imports = [ ./nix/pre-commit.nix ];

      perSystem =
        {
          config,
          pkgs,
          system,
          ...
        }:
        {
          devShells.default = pkgs.mkShell {
            name = "tree-sitter-nim-dev";

            buildInputs = [
              # Node.js for the Node bindings and dev workflow
              pkgs.nodejs_20

              # tree-sitter CLI and library
              pkgs.tree-sitter

              # Nim compiler for tests
              pkgs.nim

              # For building native Node modules
              pkgs.python3

              # Development tools
              pkgs.just
              pkgs.nodePackages.prettier

              # Pre-commit
              pkgs.pre-commit
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              # C compiler for Linux
              pkgs.gcc
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              # libiconv needed for tree-sitter on macOS
              pkgs.libiconv
            ]
            ++ config.pre-commit.settings.enabledPackages;

            shellHook = ''
              # Install git pre-commit hooks
              ${config.pre-commit.settings.installationScript}

              echo "tree-sitter-nim development environment"
              echo ""
              echo "Available commands (via just):"
              just --list
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
