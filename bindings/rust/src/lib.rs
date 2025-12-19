use tree_sitter::Language;

extern "C" {
    fn tree_sitter_nim() -> Language;
}

pub fn language() -> Language {
    unsafe { tree_sitter_nim() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loads_language() {
        let _ = language();
    }
}
