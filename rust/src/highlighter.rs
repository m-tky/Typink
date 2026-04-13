use serde::{Deserialize, Serialize};
use typst_syntax::{LinkedNode, Source};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HighlightSpan {
    pub start: usize,
    pub end: usize,
    pub label: String,
}

pub fn highlight_typst(content: &str) -> Vec<HighlightSpan> {
    let source = Source::detached(content);
    let root = LinkedNode::new(source.root());
    let mut spans = Vec::new();
    
    // Create a byte-to-UTF16 index map
    let mut byte_to_u16 = vec![0; content.len() + 1];
    let mut u16_idx = 0;
    for (byte_idx, c) in content.char_indices() {
        byte_to_u16[byte_idx] = u16_idx;
        u16_idx += c.len_utf16();
    }
    byte_to_u16[content.len()] = u16_idx;

    traverse_and_collect(&root, &mut spans, &byte_to_u16, None, 0);
    
    spans
}

fn traverse_and_collect(
    node: &LinkedNode, 
    spans: &mut Vec<HighlightSpan>, 
    byte_to_u16: &[usize],
    parent_tag: Option<String>, 
    depth: usize
) {
    if depth > 32 { return; }
    
    let current_tag = typst_syntax::highlight(node);
    let effective_tag = current_tag.map(|t| normalize_tag(t)).or(parent_tag);

    let mut is_leaf = true;
    for child in node.children() {
        is_leaf = false;
        traverse_and_collect(&child, spans, byte_to_u16, effective_tag.clone(), depth + 1);
    }

    if is_leaf {
        if let Some(tag) = &effective_tag {
            spans.push(HighlightSpan {
                start: byte_to_u16[node.offset()],
                end: byte_to_u16[node.range().end],
                label: tag.clone(),
            });
        }
    }
}

fn normalize_tag(tag: typst_syntax::Tag) -> String {
    let s = format!("{:?}", tag);
    if s.contains("Heading") { return "heading".to_string(); }
    if s.contains("Math") { return "math".to_string(); }
    if s.contains("Function") || s.contains("Decorator") { return "function".to_string(); }
    if s.contains("Variable") { return "variable".to_string(); }
    if s.contains("Keyword") { return "keyword".to_string(); }
    if s.contains("String") { return "string".to_string(); }
    if s.contains("Comment") { return "comment".to_string(); }
    s.to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_highlighting() {
        let content = "= Heading\n$ x + y $";
        let spans = highlight_typst(content);
        println!("DEBUG SPANS: {:#?}", spans);
        
        // Final verification for pro highlighting
        let heading_spans: Vec<_> = spans.iter().filter(|s| s.label == "heading").collect();
        assert!(!heading_spans.is_empty(), "Heading not highlighted");
        
        // Ensure 'Heading' tag is propagated to the text part
        let has_text_highlight = heading_spans.iter().any(|s| s.start > 1);
        assert!(has_text_highlight, "Heading text failed to inherit tag");

        let math_spans: Vec<_> = spans.iter().filter(|s| s.label == "math").collect();
        assert!(!math_spans.is_empty(), "Math not highlighted");
    }
}
