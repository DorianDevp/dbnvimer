//! A dialect-tolerant SQL statement splitter.
//!
//! The Lua side used to split on a trailing `;`, which breaks on semicolons
//! inside string literals and comments, and on stored routine bodies that need
//! a `DELIMITER` change. This splitter understands:
//!
//! * single, double and backtick quoted identifiers/strings,
//! * `--`, `#` line comments and `/* */` block comments (nested, as PostgreSQL
//!   allows),
//! * PostgreSQL dollar quoting (`$$ ... $$` and `$tag$ ... $tag$`),
//! * MySQL backslash escapes inside single quoted strings,
//! * the MySQL client `DELIMITER` directive.

use serde::Serialize;

/// One statement located inside a larger script.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Statement {
    /// Byte offset of the first character of the statement.
    pub start: usize,
    /// Byte offset one past the last character (excluding the terminator).
    pub end: usize,
    /// Statement text with surrounding whitespace trimmed.
    pub text: String,
    /// Lowercase leading keyword, e.g. `select`, `insert`, `with`.
    pub kind: String,
    /// True when the statement is expected to return a result set.
    pub returns_rows: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Normal,
    LineComment,
    BlockComment,
    Single,
    Double,
    Backtick,
    Dollar,
}

/// Split `sql` into statements.
///
/// Empty fragments (a stray `;`, a comment-only tail) are dropped. Comments
/// that precede a statement are kept as part of it so that `-- @conn:` style
/// headers travel with the query they annotate.
pub fn split(sql: &str) -> Vec<Statement> {
    let bytes = sql.as_bytes();
    let mut statements = Vec::new();
    let mut mode = Mode::Normal;
    let mut delimiter: Vec<u8> = vec![b';'];
    let mut dollar_tag: Vec<u8> = Vec::new();
    let mut block_depth = 0usize;
    let mut start = 0usize;
    let mut index = 0usize;

    while index < bytes.len() {
        let byte = bytes[index];

        match mode {
            Mode::Normal => {
                // A `DELIMITER x` directive only counts at the start of a line.
                if at_line_start(bytes, index) {
                    if let Some((new_delimiter, consumed)) = parse_delimiter(bytes, index) {
                        // Flush anything pending before the directive.
                        push_statement(&mut statements, sql, start, index);
                        delimiter = new_delimiter;
                        index += consumed;
                        start = index;
                        continue;
                    }
                }

                if starts_with(bytes, index, b"--") {
                    mode = Mode::LineComment;
                    index += 2;
                    continue;
                }
                if byte == b'#' {
                    mode = Mode::LineComment;
                    index += 1;
                    continue;
                }
                if starts_with(bytes, index, b"/*") {
                    mode = Mode::BlockComment;
                    block_depth = 1;
                    index += 2;
                    continue;
                }
                if byte == b'\'' {
                    mode = Mode::Single;
                    index += 1;
                    continue;
                }
                if byte == b'"' {
                    mode = Mode::Double;
                    index += 1;
                    continue;
                }
                if byte == b'`' {
                    mode = Mode::Backtick;
                    index += 1;
                    continue;
                }
                if byte == b'$' {
                    if let Some(tag) = parse_dollar_tag(bytes, index) {
                        index += tag.len();
                        dollar_tag = tag;
                        mode = Mode::Dollar;
                        continue;
                    }
                }
                if starts_with(bytes, index, &delimiter) {
                    push_statement(&mut statements, sql, start, index);
                    index += delimiter.len();
                    start = index;
                    continue;
                }
                index += 1;
            }
            Mode::LineComment => {
                if byte == b'\n' {
                    mode = Mode::Normal;
                }
                index += 1;
            }
            Mode::BlockComment => {
                if starts_with(bytes, index, b"/*") {
                    block_depth += 1;
                    index += 2;
                    continue;
                }
                if starts_with(bytes, index, b"*/") {
                    block_depth -= 1;
                    index += 2;
                    if block_depth == 0 {
                        mode = Mode::Normal;
                    }
                    continue;
                }
                index += 1;
            }
            Mode::Single => {
                if byte == b'\\' && index + 1 < bytes.len() {
                    index += 2;
                    continue;
                }
                if byte == b'\'' {
                    // A doubled quote is an escaped quote, not a terminator.
                    if bytes.get(index + 1) == Some(&b'\'') {
                        index += 2;
                        continue;
                    }
                    mode = Mode::Normal;
                }
                index += 1;
            }
            Mode::Double => {
                if byte == b'\\' && index + 1 < bytes.len() {
                    index += 2;
                    continue;
                }
                if byte == b'"' {
                    if bytes.get(index + 1) == Some(&b'"') {
                        index += 2;
                        continue;
                    }
                    mode = Mode::Normal;
                }
                index += 1;
            }
            Mode::Backtick => {
                if byte == b'`' {
                    if bytes.get(index + 1) == Some(&b'`') {
                        index += 2;
                        continue;
                    }
                    mode = Mode::Normal;
                }
                index += 1;
            }
            Mode::Dollar => {
                if byte == b'$' && starts_with(bytes, index, &dollar_tag) {
                    index += dollar_tag.len();
                    mode = Mode::Normal;
                    continue;
                }
                index += 1;
            }
        }
    }

    push_statement(&mut statements, sql, start, bytes.len());
    statements
}

/// Return the statement containing byte `offset`, if any.
pub fn statement_at(sql: &str, offset: usize) -> Option<Statement> {
    let statements = split(sql);
    statements
        .iter()
        .find(|statement| offset >= statement.start && offset <= statement.end)
        .or_else(|| statements.last())
        .cloned()
}

fn push_statement(out: &mut Vec<Statement>, sql: &str, start: usize, end: usize) {
    if start >= end || end > sql.len() {
        return;
    }
    let raw = &sql[start..end];
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return;
    }
    // Keep byte offsets aligned with the trimmed text.
    let lead = raw.len() - raw.trim_start().len();
    let tail = raw.len() - raw.trim_end().len();
    let kind = leading_keyword(trimmed);
    out.push(Statement {
        start: start + lead,
        end: end - tail,
        text: trimmed.to_string(),
        returns_rows: kind_returns_rows(&kind),
        kind,
    });
}

/// Strip leading comments and return the first bare keyword, lowercased.
pub fn leading_keyword(sql: &str) -> String {
    let bytes = sql.as_bytes();
    let mut index = 0usize;

    loop {
        while index < bytes.len() && bytes[index].is_ascii_whitespace() {
            index += 1;
        }
        if starts_with(bytes, index, b"--") || bytes.get(index) == Some(&b'#') {
            while index < bytes.len() && bytes[index] != b'\n' {
                index += 1;
            }
            continue;
        }
        if starts_with(bytes, index, b"/*") {
            index += 2;
            let mut depth = 1usize;
            while index < bytes.len() && depth > 0 {
                if starts_with(bytes, index, b"/*") {
                    depth += 1;
                    index += 2;
                } else if starts_with(bytes, index, b"*/") {
                    depth -= 1;
                    index += 2;
                } else {
                    index += 1;
                }
            }
            continue;
        }
        break;
    }

    let start = index;
    while index < bytes.len() && (bytes[index].is_ascii_alphanumeric() || bytes[index] == b'_') {
        index += 1;
    }
    sql[start..index].to_ascii_lowercase()
}

fn kind_returns_rows(kind: &str) -> bool {
    matches!(
        kind,
        "select"
            | "with"
            | "show"
            | "explain"
            | "describe"
            | "desc"
            | "values"
            | "table"
            | "pragma"
    )
}

/// True when statements of this kind modify data or schema.
pub fn kind_is_write(kind: &str) -> bool {
    matches!(
        kind,
        "insert"
            | "update"
            | "delete"
            | "replace"
            | "merge"
            | "truncate"
            | "drop"
            | "create"
            | "alter"
            | "grant"
            | "revoke"
            | "rename"
            | "call"
            | "do"
            | "copy"
            | "load"
            | "vacuum"
            | "reindex"
            | "cluster"
            | "refresh"
    )
}

/// True when a write statement lacks a `where` clause, used by the linter and
/// by the write guard.
pub fn is_unfiltered_write(sql: &str) -> bool {
    let kind = leading_keyword(sql);
    if !matches!(kind.as_str(), "update" | "delete") {
        return false;
    }
    !contains_keyword(sql, "where")
}

/// Case-insensitive search for a bare keyword outside of strings and comments.
pub fn contains_keyword(sql: &str, keyword: &str) -> bool {
    let haystack = strip_noise(sql).to_ascii_lowercase();
    let needle = keyword.to_ascii_lowercase();
    let bytes = haystack.as_bytes();
    let mut index = 0usize;
    while let Some(found) = haystack[index..].find(&needle) {
        let at = index + found;
        let before_ok = at == 0 || !is_word_byte(bytes[at - 1]);
        let after = at + needle.len();
        let after_ok = after >= bytes.len() || !is_word_byte(bytes[after]);
        if before_ok && after_ok {
            return true;
        }
        index = at + needle.len();
        if index >= haystack.len() {
            break;
        }
    }
    false
}

/// Replace string literals and comments with spaces so keyword scans do not
/// trip over user data.
pub fn strip_noise(sql: &str) -> String {
    let bytes = sql.as_bytes();
    let mut out = String::with_capacity(sql.len());
    let mut index = 0usize;
    let mut mode = Mode::Normal;
    let mut dollar_tag: Vec<u8> = Vec::new();
    let mut block_depth = 0usize;

    while index < bytes.len() {
        let byte = bytes[index];
        match mode {
            Mode::Normal => {
                if starts_with(bytes, index, b"--") || byte == b'#' {
                    mode = Mode::LineComment;
                    out.push(' ');
                    index += 1;
                    continue;
                }
                if starts_with(bytes, index, b"/*") {
                    mode = Mode::BlockComment;
                    block_depth = 1;
                    out.push_str("  ");
                    index += 2;
                    continue;
                }
                if byte == b'\'' {
                    mode = Mode::Single;
                    out.push(' ');
                    index += 1;
                    continue;
                }
                if byte == b'$' {
                    if let Some(tag) = parse_dollar_tag(bytes, index) {
                        out.extend(std::iter::repeat_n(' ', tag.len()));
                        index += tag.len();
                        dollar_tag = tag;
                        mode = Mode::Dollar;
                        continue;
                    }
                }
                out.push(byte as char);
                index += 1;
            }
            Mode::LineComment => {
                if byte == b'\n' {
                    mode = Mode::Normal;
                    out.push('\n');
                } else {
                    out.push(' ');
                }
                index += 1;
            }
            Mode::BlockComment => {
                if starts_with(bytes, index, b"/*") {
                    block_depth += 1;
                    out.push_str("  ");
                    index += 2;
                    continue;
                }
                if starts_with(bytes, index, b"*/") {
                    block_depth -= 1;
                    out.push_str("  ");
                    index += 2;
                    if block_depth == 0 {
                        mode = Mode::Normal;
                    }
                    continue;
                }
                out.push(if byte == b'\n' { '\n' } else { ' ' });
                index += 1;
            }
            Mode::Single => {
                if byte == b'\\' && index + 1 < bytes.len() {
                    out.push_str("  ");
                    index += 2;
                    continue;
                }
                if byte == b'\'' {
                    if bytes.get(index + 1) == Some(&b'\'') {
                        out.push_str("  ");
                        index += 2;
                        continue;
                    }
                    mode = Mode::Normal;
                }
                out.push(' ');
                index += 1;
            }
            Mode::Dollar => {
                if byte == b'$' && starts_with(bytes, index, &dollar_tag) {
                    out.extend(std::iter::repeat_n(' ', dollar_tag.len()));
                    index += dollar_tag.len();
                    mode = Mode::Normal;
                    continue;
                }
                out.push(if byte == b'\n' { '\n' } else { ' ' });
                index += 1;
            }
            _ => {
                out.push(byte as char);
                index += 1;
            }
        }
    }

    out
}

fn is_word_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_'
}

fn at_line_start(bytes: &[u8], index: usize) -> bool {
    let mut cursor = index;
    while cursor > 0 {
        cursor -= 1;
        match bytes[cursor] {
            b'\n' => return true,
            b' ' | b'\t' | b'\r' => continue,
            _ => return false,
        }
    }
    true
}

/// Parse `DELIMITER xx` at `index`, returning the new delimiter and how many
/// bytes the directive occupies.
fn parse_delimiter(bytes: &[u8], index: usize) -> Option<(Vec<u8>, usize)> {
    const KEYWORD: &[u8] = b"delimiter";
    if index + KEYWORD.len() > bytes.len() {
        return None;
    }
    let candidate = &bytes[index..index + KEYWORD.len()];
    if !candidate.eq_ignore_ascii_case(KEYWORD) {
        return None;
    }

    let mut cursor = index + KEYWORD.len();
    let mut saw_space = false;
    while cursor < bytes.len() && (bytes[cursor] == b' ' || bytes[cursor] == b'\t') {
        cursor += 1;
        saw_space = true;
    }
    if !saw_space {
        return None;
    }

    let start = cursor;
    while cursor < bytes.len() && !bytes[cursor].is_ascii_whitespace() {
        cursor += 1;
    }
    if cursor == start {
        return None;
    }

    let delimiter = bytes[start..cursor].to_vec();
    // Consume the rest of the line so the directive never reaches the server.
    while cursor < bytes.len() && bytes[cursor] != b'\n' {
        cursor += 1;
    }
    if cursor < bytes.len() {
        cursor += 1;
    }
    Some((delimiter, cursor - index))
}

/// Parse a PostgreSQL dollar quote opening tag at `index` (`$$` or `$tag$`).
fn parse_dollar_tag(bytes: &[u8], index: usize) -> Option<Vec<u8>> {
    if bytes.get(index) != Some(&b'$') {
        return None;
    }
    let mut cursor = index + 1;
    while cursor < bytes.len() && (bytes[cursor].is_ascii_alphanumeric() || bytes[cursor] == b'_') {
        cursor += 1;
    }
    if bytes.get(cursor) != Some(&b'$') {
        return None;
    }
    Some(bytes[index..=cursor].to_vec())
}

fn starts_with(bytes: &[u8], index: usize, prefix: &[u8]) -> bool {
    if prefix.is_empty() || index + prefix.len() > bytes.len() {
        return false;
    }
    &bytes[index..index + prefix.len()] == prefix
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(sql: &str) -> Vec<String> {
        split(sql).into_iter().map(|s| s.text).collect()
    }

    #[test]
    fn splits_plain_statements() {
        assert_eq!(
            texts("select 1; select 2;"),
            vec!["select 1".to_string(), "select 2".to_string()]
        );
    }

    #[test]
    fn keeps_semicolons_inside_strings() {
        assert_eq!(
            texts("select ';'; select 2"),
            vec!["select ';'", "select 2"]
        );
    }

    #[test]
    fn handles_doubled_quotes() {
        assert_eq!(texts("select 'it''s; fine'"), vec!["select 'it''s; fine'"]);
    }

    #[test]
    fn handles_backslash_escape() {
        assert_eq!(texts(r"select 'a\'; b'"), vec![r"select 'a\'; b'"]);
    }

    #[test]
    fn ignores_semicolons_in_line_comments() {
        assert_eq!(
            texts("select 1 -- ; not a split\n; select 2"),
            vec!["select 1 -- ; not a split", "select 2"]
        );
    }

    #[test]
    fn ignores_semicolons_in_block_comments() {
        assert_eq!(
            texts("select /* ; */ 1; select 2"),
            vec!["select /* ; */ 1", "select 2"]
        );
    }

    #[test]
    fn supports_nested_block_comments() {
        assert_eq!(
            texts("select /* a /* b ; */ c */ 1"),
            vec!["select /* a /* b ; */ c */ 1"]
        );
    }

    #[test]
    fn supports_dollar_quoting() {
        let sql = "create function f() returns int as $$ begin return 1; end $$ language plpgsql; select 1";
        assert_eq!(
            texts(sql),
            vec![
                "create function f() returns int as $$ begin return 1; end $$ language plpgsql",
                "select 1"
            ]
        );
    }

    #[test]
    fn supports_tagged_dollar_quoting() {
        let sql = "select $tag$ ; still inside $tag$; select 2";
        assert_eq!(
            texts(sql),
            vec!["select $tag$ ; still inside $tag$", "select 2"]
        );
    }

    #[test]
    fn supports_delimiter_directive() {
        let sql = "delimiter //\ncreate procedure p() begin select 1; select 2; end //\ndelimiter ;\nselect 3;";
        assert_eq!(
            texts(sql),
            vec![
                "create procedure p() begin select 1; select 2; end",
                "select 3"
            ]
        );
    }

    #[test]
    fn classifies_statement_kind() {
        let statements = split("with x as (select 1) select * from x; insert into t values (1)");
        assert_eq!(statements[0].kind, "with");
        assert!(statements[0].returns_rows);
        assert_eq!(statements[1].kind, "insert");
        assert!(!statements[1].returns_rows);
    }

    #[test]
    fn skips_leading_comments_when_classifying() {
        assert_eq!(leading_keyword("-- @conn: prod\nselect 1"), "select");
        assert_eq!(leading_keyword("/* header */ update t set a = 1"), "update");
    }

    #[test]
    fn offsets_point_at_trimmed_text() {
        let sql = "  select 1;\n\n  select 2;";
        let statements = split(sql);
        assert_eq!(&sql[statements[0].start..statements[0].end], "select 1");
        assert_eq!(&sql[statements[1].start..statements[1].end], "select 2");
    }

    #[test]
    fn statement_at_offset() {
        let sql = "select 1;\nselect 2;";
        let found = statement_at(sql, 12).unwrap();
        assert_eq!(found.text, "select 2");
    }

    #[test]
    fn detects_unfiltered_writes() {
        assert!(is_unfiltered_write("delete from users"));
        assert!(is_unfiltered_write("update users set a = 1"));
        assert!(!is_unfiltered_write("update users set a = 1 where id = 2"));
        // `where` inside a literal must not count as a filter.
        assert!(is_unfiltered_write("update t set note = 'where'"));
        assert!(!is_unfiltered_write("select * from t"));
    }

    #[test]
    fn keyword_scan_ignores_comments() {
        assert!(!contains_keyword("delete from t -- where id = 1", "where"));
        assert!(contains_keyword("delete from t where id = 1", "where"));
        // Substrings must not match.
        assert!(!contains_keyword("select somewhere from t", "where"));
    }

    #[test]
    fn trailing_statement_without_terminator() {
        assert_eq!(texts("select 1"), vec!["select 1"]);
    }

    #[test]
    fn drops_empty_fragments() {
        assert_eq!(texts(";;\n;  ;"), Vec::<String>::new());
    }
}
