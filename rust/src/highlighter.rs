use serde::{Deserialize, Serialize};
use typst_syntax::{LinkedNode, Source};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HighlightSpan {
    pub start: usize,
    pub end: usize,
    pub label: String,
    pub bold: bool,
    pub italic: bool,
    pub heading_level: Option<u8>,
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

    let mut bracket_depth = 0;
    traverse_and_collect(
        &root,
        &mut spans,
        &byte_to_u16,
        None,
        false,
        false,
        None,
        0,
        &mut bracket_depth,
    );

    spans
}

#[allow(clippy::too_many_arguments)]
fn traverse_and_collect(
    node: &LinkedNode,
    spans: &mut Vec<HighlightSpan>,
    byte_to_u16: &[usize],
    parent_tag: Option<String>,
    bold: bool,
    italic: bool,
    heading_level: Option<u8>,
    depth: usize,
    bracket_depth: &mut usize,
) {
    if depth > 32 {
        return;
    }

    let kind = node.kind();
    let _current_tag = typst_syntax::highlight(node);

    // Check if we are inside math
    let in_math = kind == typst_syntax::SyntaxKind::Equation
        || (parent_tag
            .as_ref()
            .map(|t| t.starts_with("math"))
            .unwrap_or(false));

    // Get highlight tag from Typst
    let current_tag = typst_syntax::highlight(node);
    let mut effective_tag = current_tag.map(|t| normalize_tag(t, in_math));

    // Manual overrides for math and brackets (Prioritize manual tag in math)
    if in_math {
        if let Some(manual) = manual_math_tag(kind, node.text()) {
            effective_tag = Some(manual);
        }
    }

    if effective_tag.is_none() {
        if kind == typst_syntax::SyntaxKind::Equation {
            effective_tag = Some("math".to_string());
        } else {
            effective_tag = parent_tag.clone();
        }
    }

    // Rainbow Brackets logic
    let is_opening = matches!(
        kind,
        typst_syntax::SyntaxKind::LeftParen
            | typst_syntax::SyntaxKind::LeftBracket
            | typst_syntax::SyntaxKind::LeftBrace
    );
    let is_closing = matches!(
        kind,
        typst_syntax::SyntaxKind::RightParen
            | typst_syntax::SyntaxKind::RightBracket
            | typst_syntax::SyntaxKind::RightBrace
    );

    if is_opening {
        *bracket_depth += 1;
        let level = ((*bracket_depth - 1) % 5) + 1;
        effective_tag = Some(format!("delimiter.L{}", level));
    } else if is_closing {
        let level = ((*bracket_depth - 1) % 5) + 1;
        effective_tag = Some(format!("delimiter.L{}", level));
    }

    let mut is_bold = bold;
    let mut is_italic = italic;
    let mut current_heading_level = heading_level;

    match kind {
        typst_syntax::SyntaxKind::Strong => is_bold = true,
        typst_syntax::SyntaxKind::Emph => is_italic = true,
        typst_syntax::SyntaxKind::MathIdent => is_italic = true,
        typst_syntax::SyntaxKind::Heading => {
            if let Some(marker) = node
                .children()
                .find(|c| c.kind() == typst_syntax::SyntaxKind::HeadingMarker)
            {
                current_heading_level = Some(marker.range().len() as u8);
            }
        }
        _ => {}
    }

    let is_leaf = node.children().next().is_none();
    if is_leaf {
        let text = node.text();
        let mut char_offset = 0;
        let node_start = node.offset();
        let mut last_pushed_offset = 0;

        for c in text.chars() {
            let c_len = c.len_utf8();
            let is_op = matches!(c, '(' | '[' | '{');
            let is_cl = matches!(c, ')' | ']' | '}');

            if is_op || is_cl {
                // Push pending non-bracket text
                if char_offset > last_pushed_offset
                    && (effective_tag.is_some() || current_heading_level.is_some())
                {
                    spans.push(HighlightSpan {
                        start: byte_to_u16[node_start + last_pushed_offset],
                        end: byte_to_u16[node_start + char_offset],
                        label: effective_tag.clone().unwrap_or_else(|| "text".to_string()),
                        bold: is_bold,
                        italic: is_italic,
                        heading_level: current_heading_level,
                    });
                }

                if is_op {
                    *bracket_depth += 1;
                }
                let level = ((*bracket_depth as i32 - 1).max(0) % 5) + 1;
                let tag = format!("delimiter.L{}", level);

                spans.push(HighlightSpan {
                    start: byte_to_u16[node_start + char_offset],
                    end: byte_to_u16[node_start + char_offset + c_len],
                    label: tag,
                    bold: is_bold,
                    italic: is_italic,
                    heading_level: current_heading_level,
                });

                if is_cl {
                    *bracket_depth = bracket_depth.saturating_sub(1);
                }
                last_pushed_offset = char_offset + c_len;
            }
            char_offset += c_len;
        }

        // Push remaining text
        if char_offset > last_pushed_offset
            && (effective_tag.is_some() || current_heading_level.is_some())
        {
            spans.push(HighlightSpan {
                start: byte_to_u16[node_start + last_pushed_offset],
                end: byte_to_u16[node_start + char_offset],
                label: effective_tag.clone().unwrap_or_else(|| "text".to_string()),
                bold: is_bold,
                italic: is_italic,
                heading_level: current_heading_level,
            });
        }
    }

    for child in node.children() {
        traverse_and_collect(
            &child,
            spans,
            byte_to_u16,
            effective_tag.clone(),
            is_bold,
            is_italic,
            current_heading_level,
            depth + 1,
            bracket_depth,
        );
    }

    if is_closing {
        *bracket_depth = bracket_depth.saturating_sub(1);
    }
}

fn manual_math_tag(kind: typst_syntax::SyntaxKind, text: &str) -> Option<String> {
    use typst_syntax::SyntaxKind;
    match kind {
        SyntaxKind::Math => Some("math".to_string()),
        SyntaxKind::MathText => {
            if text.chars().any(|c| "+-*/=<>!&|~^".contains(c)) {
                Some("math.operator".to_string())
            } else {
                Some("math.variable".to_string())
            }
        }
        SyntaxKind::MathFrac => Some("math.operator".to_string()),
        SyntaxKind::MathRoot => Some("math.operator".to_string()),
        _ => std::option::Option::None,
    }
}

fn normalize_tag(tag: typst_syntax::Tag, in_math: bool) -> String {
    let s = format!("{:?}", tag);
    let mut label = if s.contains("Heading") {
        "heading".to_string()
    } else if s.contains("Math") {
        "math".to_string()
    } else if s.contains("Function") || s.contains("Decorator") {
        "function".to_string()
    } else if s.contains("Variable") {
        "variable".to_string()
    } else if s.contains("Keyword") {
        "keyword".to_string()
    } else if s.contains("String") {
        "string".to_string()
    } else if s.contains("Comment") {
        "comment".to_string()
    } else if s.contains("Operator") {
        "operator".to_string()
    } else if s.contains("Punctuation") {
        "punctuation".to_string()
    } else if s.contains("Raw") {
        "raw".to_string()
    } else if s.contains("Label") {
        "label".to_string()
    } else if s.contains("Ref") {
        "ref".to_string()
    } else if s.contains("Url") {
        "link".to_string()
    } else if s.contains("Marker") {
        "marker".to_string()
    } else if s.contains("Error") {
        "error".to_string()
    } else {
        s.to_lowercase()
    };

    if in_math && !label.starts_with("math") && !label.starts_with("delimiter.") {
        label = format!("math.{}", label);
    }
    label
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_highlighting() {
        let content = "= Heading\n== Sub\n$ x + y $";
        let spans = highlight_typst(content);
        for span in &spans {
            // Find the node to get its kind
            println!(
                "Span: [{}, {}] -> label: {}",
                span.start, span.end, span.label
            );
        }

        let h1_spans: Vec<_> = spans
            .iter()
            .filter(|s| s.heading_level == Some(1))
            .collect();
        assert!(!h1_spans.is_empty(), "Level 1 heading not found");

        let h2_spans: Vec<_> = spans
            .iter()
            .filter(|s| s.heading_level == Some(2))
            .collect();
        assert!(!h2_spans.is_empty(), "Level 2 heading not found");

        let math_item_spans: Vec<_> = spans
            .iter()
            .filter(|s| s.label.starts_with("math."))
            .collect();
        assert!(!math_item_spans.is_empty(), "Granular math not highlighted");
    }
}
