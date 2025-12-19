{ inputs, ... }:
{
  imports = [ inputs.git-hooks.flakeModule ];

  perSystem =
    { pkgs, ... }:
    {
      pre-commit = {
        settings = {
          hooks = {
            # Nix formatting
            nixfmt.enable = true;

            # JavaScript/JSON formatting with Prettier
            prettier = {
              enable = true;
              excludes = [
                "node_modules"
                "build"
                "src/grammar.json"
                "src/node-types.json"
              ];
              settings = {
                check = true;
                write = true;
                list-different = false;
                ignore-unknown = true;
                log-level = "warn";
              };
            };

            # General file checks
            check-merge-conflict = {
              enable = true;
              name = "check merge conflict markers";
              # Exclude test/corpus files which use ================== as separators
              excludes = [ "^test/corpus/" ];
              entry = ''
                bash -lc 'set -e; rc=0; for f in "$@"; do [ -f "$f" ] || continue; if ${pkgs.ripgrep}/bin/rg -n "^(<<<<<<<|=======|>>>>>>>)" --color never --hidden --glob "!*.rej" --no-ignore-vcs -- "$f" >/dev/null; then echo "Merge conflict markers in $f"; rc=1; fi; done; exit $rc' --
              '';
              language = "system";
              pass_filenames = true;
              types = [ "text" ];
            };

            check-added-large-files = {
              enable = true;
              name = "check added large files (>1MB)";
              entry = ''
                bash -lc 'set -e; limit="$LIMIT"; [ -z "$limit" ] && limit=1048576; rc=0; for f in "$@"; do [ -f "$f" ] || continue; sz=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f"); if [ "$sz" -gt "$limit" ]; then echo "File too large: $f ($sz bytes)"; rc=1; fi; done; exit $rc' --
              '';
              language = "system";
              pass_filenames = true;
            };

            # Tree-sitter grammar generation (requires node)
            tree-sitter-generate = {
              enable = true;
              name = "tree-sitter generate";
              entry = ''
                bash -lc 'PATH="${pkgs.nodejs_20}/bin:$PATH" ${pkgs.tree-sitter}/bin/tree-sitter generate' --
              '';
              language = "system";
              pass_filenames = false;
              files = "^grammar\\.js$";
            };

            # Tree-sitter tests (on pre-push only for speed)
            tree-sitter-test = {
              enable = true;
              name = "tree-sitter test";
              entry = ''
                bash -lc 'PATH="${pkgs.nodejs_20}/bin:$PATH" ${pkgs.tree-sitter}/bin/tree-sitter test' --
              '';
              language = "system";
              pass_filenames = false;
              files = "^(grammar\\.js|test/corpus/.*\\.txt|src/scanner\\.c)$";
              stages = [ "pre-push" ];
            };
          };
        };
      };
    };
}
