mod tests {
    use super::*;

    #[test]
    fn test_normal_movements() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("Hello\nWorld\nTypink");
        vim.handle_key("j", &content);
        assert_eq!(vim.line, 1);
        vim.handle_key("l", &content);
        assert_eq!(vim.col, 1);
        vim.handle_key("h", &content);
        assert_eq!(vim.col, 0);
        vim.handle_key("k", &content);
        assert_eq!(vim.line, 0);
    }

    #[test]
    fn test_word_movements() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("Hello world typink");
        vim.handle_key("w", &content);
        assert_eq!(vim.col, 6);
        vim.handle_key("e", &content);
        assert_eq!(vim.col, 10);
        vim.handle_key("b", &content);
        assert_eq!(vim.col, 6);
    }

    #[test]
    fn test_search_mode() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("Find me in middle");
        vim.handle_key("/", &content);
        vim.handle_key("m", &content);
        vim.handle_key("e", &content);
        vim.handle_key("Enter", &content);
        assert_eq!(vim.col, 5);
    }

    #[test]
    fn test_char_operations() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("Hello");
        // x
        let _action = vim.handle_key("x", &content).unwrap();
        
        // X
        vim.col = 1;
        let _action = vim.handle_key("X", &content).unwrap();
        assert_eq!(vim.col, 0);
    }

    #[test]
    fn test_append_at_end_of_file() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("abc");
        vim.col = 2; // on 'c'
        vim.handle_key("a", &content);
        assert_eq!(vim.mode, VimMode::Insert);
        assert_eq!(vim.col, 3); // should be after 'c'
    }

    #[test]
    fn test_normal_mode_boundary() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("abc\n");
        vim.col = 2; // on 'c'
        vim.handle_key("l", &content);
        // In standard Vim, 'l' stops at 'c' (index 2). 
        // But some implementations allow landing on \n. 
        // The user specifically said they DON'T need landing on \n.
        // So let's make it stay on 'c'.
        assert_eq!(vim.col, 2);
    }
        
        // r
        vim.col = 0;
        vim.handle_key("r", content);
        let action = vim.handle_key("y", content).unwrap();
        assert_eq!(action.insert_text.unwrap(), "y");
    }

    #[test]
    fn test_line_search() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("banana");
        // f
        vim.handle_key("f", &content);
        vim.handle_key("n", &content);
        assert_eq!(vim.col, 2);
        
        // t
        vim.col = 0;
        vim.handle_key("t", &content);
        vim.handle_key("n", &content);
        assert_eq!(vim.col, 1);
        
        // F
        vim.col = 5;
        vim.handle_key("F", &content);
        vim.handle_key("a", &content);
        assert_eq!(vim.col, 3);
    }

    #[test]
    fn test_bracket_match() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("fn main() { ... }");
        // % on (
        vim.col = 7;
        vim.handle_key("%", &content);
        assert_eq!(vim.col, 8); // )
        
        // % on {
        vim.col = 10;
        vim.handle_key("%", &content);
        assert_eq!(vim.col, 16); // }
    }

    #[test]
    fn test_paragraph_move() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("Para 1\n\nPara 2\n\nPara 3");
        // }
        vim.handle_key("}", &content);
        assert_eq!(vim.line, 1);
        vim.handle_key("}", &content);
        assert_eq!(vim.line, 3);
        
        // {
        vim.handle_key("{", &content);
        assert_eq!(vim.line, 1);
    }

    #[test]
    fn test_word_search() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("apple banana apple cherry");
        // * on first apple
        vim.handle_key("*", &content);
        assert_eq!(vim.col, 13);
        assert_eq!(vim.last_search.as_deref(), Some("apple"));
    }

    #[test]
    fn test_line_end_ops() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("Hello World");
        // D
        vim.col = 6;
        let _action = vim.handle_key("D", &content).unwrap();
        
        // C
        vim.col = 6;
        let _action = vim.handle_key("C", &content).unwrap();
        assert_eq!(vim.mode, VimMode::Insert);
    }
    #[test]
    fn test_counts() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("Line 1\nLine 2\nLine 3\nLine 4\nLine 5");
        
        // 3j
        vim.handle_key("3", &content);
        vim.handle_key("j", &content);
        assert_eq!(vim.line, 3);
        
        // 2k
        vim.handle_key("2", &content);
        vim.handle_key("k", &content);
        assert_eq!(vim.line, 1);
        
        // 5x
        let content2 = ropey::Rope::from_str("abcdefghij");
        vim.line = 0; vim.col = 0;
        vim.handle_key("5", &content2);
        let action = vim.handle_key("x", &content2).unwrap();
        assert_eq!(action.delete_range.unwrap().end_column, 5);
        
        // 3dd
        vim.line = 0;
        vim.handle_key("3", &content);
        vim.handle_key("d", &content);
        let action = vim.handle_key("d", &content).unwrap();
        assert_eq!(action.delete_range.unwrap().end_line, 3);
        
        // d2w
        vim.line = 0; vim.col = 0;
        let content3 = ropey::Rope::from_str("one two three four");
        vim.handle_key("d", &content3);
        vim.handle_key("2", &content3);
        let action = vim.handle_key("w", &content3).unwrap();
        assert_eq!(action.delete_range.unwrap().end_column, 8); // "one two "
        
        // 3d2w
        vim.handle_key("3", &content3);
        vim.handle_key("d", &content3);
        vim.handle_key("2", &content3);
        let action = vim.handle_key("w", &content3).unwrap();
        // 3 * 2 = 6 words. Since content3 only has 4, it should delete to end.
        assert_eq!(action.delete_range.unwrap().end_column, content3.len_chars());
    }
    #[test]
    fn test_word_movements_upper() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("Hello-world, (test) item");
        // w stops at -
        vim.handle_key("w", &content);
        assert_eq!(vim.col, 5); // '-'
        
        // W skips to next WORD
        vim.col = 0;
        vim.handle_key("W", &content);
        assert_eq!(vim.col, 13); // '('
    }

    #[test]
    fn test_first_non_blank() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("   Indent");
        vim.handle_key("^", &content);
        assert_eq!(vim.col, 3);
    }

    #[test]
    fn test_text_objects_basics() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("word (inside) 'quote'");
        
        // diw
        vim.col = 0;
        vim.handle_key("d", &content);
        vim.handle_key("i", &content);
        let action = vim.handle_key("w", &content).unwrap();
        assert_eq!(action.delete_range.unwrap().end_column, 4);
        
        // da(
        vim.col = 7;
        vim.handle_key("d", &content);
        vim.handle_key("a", &content);
        let action = vim.handle_key("(", &content).unwrap();
        let range = action.delete_range.as_ref().unwrap();
        assert_eq!(range.start_column, 5);
        assert_eq!(range.end_column, 13);
    }

    #[test]
    fn test_sentence_move() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("Sentence one. Sentence two! Sentence three?");
        
        // ) from start
        vim.handle_key(")", &content);
        assert_eq!(vim.col, 14); // start of "Sentence two"
        
        // ) again
        vim.handle_key(")", &content);
        assert_eq!(vim.col, 28); // start of "Sentence three"
        
        // ( back
        vim.handle_key("(", &content);
        assert_eq!(vim.col, 14);
    }

    #[test]
    fn test_dot_command() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("hello world");
        
        // x at pos 0
        vim.handle_key("x", &content);
        assert_eq!(vim.last_mutation_keys, vec!["x"]);
        
        // . repeats x
        vim.col = 5;
        let action = vim.handle_key(".", &content).unwrap();
        assert_eq!(action.replay_keys.as_ref().unwrap(), &vec!["x".to_string()]);
        
        // 2dw
        vim.col = 0;
        vim.handle_key("2", &content);
        vim.handle_key("d", &content);
        vim.handle_key("w", &content);
        assert_eq!(vim.last_mutation_keys, vec!["2", "d", "w"]);
        
        // . repeats 2dw
        vim.col = 0;
        let action = vim.handle_key(".", &content).unwrap();
        assert_eq!(action.replay_keys.as_ref().unwrap(), &vec!["2".to_string(), "d".to_string(), "w".to_string()]);
        
        // Insert mode: iabc<Esc>
        vim.handle_key("i", &content);
        vim.handle_key("a", &content);
        vim.handle_key("b", &content);
        vim.handle_key("c", &content);
        vim.handle_key("Escape", &content);
        assert_eq!(vim.last_mutation_keys, vec!["i", "a", "b", "c", "Escape"]);
        
        // . repeats iabc<Esc>
        vim.col = 0;
        let action = vim.handle_key(".", &content).unwrap();
        assert_eq!(action.replay_keys.as_ref().unwrap(), &vec!["i".to_string(), "a".to_string(), "b".to_string(), "c".to_string(), "Escape".to_string()]);
    }

    #[test]
    fn test_macros() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("hello world");
        
        // qa - start recording in 'a'
        vim.handle_key("q", &content);
        vim.handle_key("a", &content);
        assert_eq!(vim.is_recording_macro, Some('a'));
        
        // w - movement
        vim.handle_key("w", &content);
        
        // q - stop recording
        vim.handle_key("q", &content);
        assert_eq!(vim.is_recording_macro, None);
        assert_eq!(vim.macro_registers.get(&'a').unwrap(), &vec!["w".to_string()]);
        
        // @a - playback (returns replay_keys)
        vim.col = 0;
        vim.handle_key("@", &content);
        let action = vim.handle_key("a", &content).unwrap();
        assert_eq!(action.replay_keys.as_ref().unwrap(), &vec!["w".to_string()]);
        
        // Test macro with count: 3x
        vim.col = 0;
        vim.handle_key("q", &content);
        vim.handle_key("b", &content);
        vim.handle_key("3", &content);
        vim.handle_key("x", &content);
        vim.handle_key("q", &content);
        
        vim.col = 0;
        vim.handle_key("@", &content);
        let action = vim.handle_key("b", &content).unwrap();
        // 3x playback signal
        assert_eq!(action.replay_keys.as_ref().unwrap(), &vec!["3".to_string(), "x".to_string()]);
    }

    #[test]
    fn test_newline_boundary_behavior() {
        let mut vim = VimEngine::new();
        let content = ropey::Rope::from_str("abc\n");
        
        // Normal mode should stop at 'c' (index 2)
        vim.col = 0;
        for _ in 0..10 { vim.handle_key("l", &content); }
        assert_eq!(vim.col, 2);
        
        // 'a' should move to index 3 (\n) and enter Insert mode
        vim.handle_key("a", &content);
        assert_eq!(vim.mode, VimMode::Insert);
        assert_eq!(vim.col, 3);
    }
}
