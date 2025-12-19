//! Nim grammar for tree-sitter.

use tree_sitter_language::LanguageFn;

extern "C" {
    fn tree_sitter_nim() -> *const ();
}

/// The tree-sitter [`LanguageFn`] for Nim.
pub const LANGUAGE: LanguageFn = unsafe { LanguageFn::from_raw(tree_sitter_nim) };

/// Returns the tree-sitter Language for Nim.
#[must_use]
pub fn language() -> tree_sitter::Language {
    LANGUAGE.into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loads_language() {
        let _ = language();
    }
}
