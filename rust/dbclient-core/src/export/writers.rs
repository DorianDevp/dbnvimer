//! Per-format writers.
//!
//! Each is a small state machine fed one row at a time, so nothing has to hold
//! the whole result set — except the two formats that genuinely cannot stream,
//! which say so.

use crate::export::xlsx::XlsxWriter;
use crate::export::{BinaryMode, Escape, ExportSpec, Format, JsonMode, Quoting, SqlMode};
use crate::protocol::{ColumnDesc, ValueClass};
use anyhow::Result;
use serde_json::Value as JsonValue;

/// Fed rows, produces bytes.
pub trait RowWriter {
    fn begin(&mut self, columns: &[ColumnDesc], out: &mut Vec<u8>) -> Result<()>;
    fn row(
        &mut self,
        columns: &[ColumnDesc],
        values: &[JsonValue],
        out: &mut Vec<u8>,
    ) -> Result<()>;
    fn finish(&mut self, out: &mut Vec<u8>) -> Result<()>;
}

/// Build the writer a spec calls for.
pub fn make(spec: &ExportSpec, columns: &[ColumnDesc]) -> Box<dyn RowWriter> {
    match spec.format {
        Format::Csv | Format::Tsv => Box::new(Delimited::new(spec)),
        Format::Json => Box::new(Json::new(spec, false)),
        Format::Jsonl => Box::new(Json::new(spec, true)),
        Format::Markdown => Box::new(Markdown::new(spec)),
        Format::Html => Box::new(Html::new(spec)),
        Format::Xml => Box::new(Xml::new(spec)),
        Format::Sql => Box::new(Sql::new(spec)),
        Format::Xlsx => Box::new(XlsxWriter::new(spec, columns)),
        Format::Text => Box::new(Text::new(spec)),
    }
}

// ---------------------------------------------------------------------------
// Value rendering
// ---------------------------------------------------------------------------

/// The text of a value, or `None` when it is SQL NULL.
///
/// Keeping NULL as `None` all the way to the writer is what lets each format
/// decide how to say "absent" — and lets CSV say it differently from an empty
/// string, which is the distinction every other tool throws away.
pub fn render(value: &JsonValue, column: &ColumnDesc, spec: &ExportSpec) -> Option<String> {
    if value.is_null() {
        return None;
    }

    let text = match value {
        JsonValue::String(text) => text.clone(),
        JsonValue::Bool(flag) => flag.to_string(),
        JsonValue::Number(number) => number.to_string(),
        other => other.to_string(),
    };

    match column.class {
        ValueClass::Binary => match spec.binary {
            BinaryMode::Hex => Some(text),
            BinaryMode::Base64 => {
                let bytes = crate::session::decode_hex(&text);
                Some(match bytes {
                    Some(bytes) => crate::session::encode_base64(&bytes),
                    None => text,
                })
            }
            BinaryMode::Omit => Some(String::new()),
        },
        ValueClass::Number => Some(match &spec.decimal_separator {
            Some(separator) if separator != "." => text.replacen('.', separator, 1),
            _ => text,
        }),
        _ => Some(text),
    }
}

fn is_numeric(column: &ColumnDesc) -> bool {
    column.class == ValueClass::Number
}

// ---------------------------------------------------------------------------
// Delimited
// ---------------------------------------------------------------------------

struct Delimited {
    delimiter: String,
    quote: char,
    quoting: Quoting,
    escape: Escape,
    header: bool,
    newline: &'static str,
    bom: bool,
    null_as: String,
    spec: ExportSpec,
    wrote_header: bool,
}

impl Delimited {
    fn new(spec: &ExportSpec) -> Self {
        Self {
            delimiter: spec.effective_delimiter(),
            quote: spec.effective_quote(),
            quoting: spec.quoting,
            escape: spec.escape,
            header: spec.header,
            newline: spec.line_ending.as_str(),
            bom: spec.bom,
            null_as: spec.effective_null(),
            spec: spec.clone(),
            wrote_header: false,
        }
    }

    fn needs_quoting(&self, text: &str, numeric: bool) -> bool {
        match self.quoting {
            Quoting::All => true,
            Quoting::None => false,
            Quoting::NonNumeric => !numeric,
            Quoting::Minimal => {
                text.contains(&self.delimiter)
                    || text.contains(self.quote)
                    || text.contains('\n')
                    || text.contains('\r')
                    || text.starts_with(' ')
                    || text.ends_with(' ')
            }
        }
    }

    fn field(&self, text: &str, numeric: bool) -> String {
        if !self.needs_quoting(text, numeric) {
            return text.to_string();
        }

        let escaped = match self.escape {
            Escape::Double => text.replace(self.quote, &format!("{0}{0}", self.quote)),
            Escape::Backslash => text
                .replace('\\', "\\\\")
                .replace(self.quote, &format!("\\{}", self.quote)),
        };
        format!("{0}{1}{0}", self.quote, escaped)
    }
}

impl RowWriter for Delimited {
    fn begin(&mut self, columns: &[ColumnDesc], out: &mut Vec<u8>) -> Result<()> {
        if self.bom {
            // Excel needs this to read UTF-8; without it `Łódź` arrives mangled.
            out.extend_from_slice(&[0xEF, 0xBB, 0xBF]);
        }
        if self.header && !self.wrote_header {
            self.wrote_header = true;
            let fields = columns
                .iter()
                .map(|column| self.field(&column.name, false))
                .collect::<Vec<_>>();
            out.extend_from_slice(fields.join(&self.delimiter).as_bytes());
            out.extend_from_slice(self.newline.as_bytes());
        }
        Ok(())
    }

    fn row(
        &mut self,
        columns: &[ColumnDesc],
        values: &[JsonValue],
        out: &mut Vec<u8>,
    ) -> Result<()> {
        let mut fields = Vec::with_capacity(values.len());
        for (index, value) in values.iter().enumerate() {
            let column = &columns[index];
            match render(value, column, &self.spec) {
                // NULL is written bare even under `quoting = all`, so an empty
                // quoted field means an empty string and nothing means NULL.
                None => fields.push(self.null_as.clone()),
                Some(text) => fields.push(self.field(&text, is_numeric(column))),
            }
        }
        out.extend_from_slice(fields.join(&self.delimiter).as_bytes());
        out.extend_from_slice(self.newline.as_bytes());
        Ok(())
    }

    fn finish(&mut self, _out: &mut Vec<u8>) -> Result<()> {
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------------

struct Json {
    lines: bool,
    newline: &'static str,
    spec: ExportSpec,
    first: bool,
    opened: bool,
}

impl Json {
    fn new(spec: &ExportSpec, lines: bool) -> Self {
        Self {
            lines,
            newline: spec.line_ending.as_str(),
            spec: spec.clone(),
            first: true,
            opened: false,
        }
    }

    fn object(&self, columns: &[ColumnDesc], values: &[JsonValue]) -> JsonValue {
        let mut map = serde_json::Map::with_capacity(values.len());
        for (index, value) in values.iter().enumerate() {
            let column = &columns[index];
            let entry = match render(value, column, &self.spec) {
                None => JsonValue::Null,
                Some(text) => match column.class {
                    // A JSON column embedded as a string produces a document
                    // full of escaped documents, which every consumer then has
                    // to parse twice. Inline it unless asked not to.
                    _ if self.spec.json_mode == JsonMode::Inline
                        && self.spec.treats_as_json(column) =>
                    {
                        serde_json::from_str(&text).unwrap_or(JsonValue::String(text))
                    }
                    ValueClass::Number => serde_json::from_str(&text)
                        .ok()
                        .filter(JsonValue::is_number)
                        .unwrap_or(JsonValue::String(text)),
                    ValueClass::Bool => match text.as_str() {
                        "true" | "t" | "1" => JsonValue::Bool(true),
                        "false" | "f" | "0" => JsonValue::Bool(false),
                        _ => JsonValue::String(text),
                    },
                    _ => JsonValue::String(text),
                },
            };
            map.insert(column.name.clone(), entry);
        }
        JsonValue::Object(map)
    }
}

impl RowWriter for Json {
    fn begin(&mut self, _columns: &[ColumnDesc], out: &mut Vec<u8>) -> Result<()> {
        if !self.lines && !self.opened {
            self.opened = true;
            out.extend_from_slice(b"[");
            out.extend_from_slice(self.newline.as_bytes());
        }
        Ok(())
    }

    fn row(
        &mut self,
        columns: &[ColumnDesc],
        values: &[JsonValue],
        out: &mut Vec<u8>,
    ) -> Result<()> {
        let encoded = serde_json::to_string(&self.object(columns, values))?;
        if self.lines {
            out.extend_from_slice(encoded.as_bytes());
            out.extend_from_slice(self.newline.as_bytes());
            return Ok(());
        }

        if !self.first {
            out.extend_from_slice(b",");
            out.extend_from_slice(self.newline.as_bytes());
        }
        self.first = false;
        out.extend_from_slice(b"  ");
        out.extend_from_slice(encoded.as_bytes());
        Ok(())
    }

    fn finish(&mut self, out: &mut Vec<u8>) -> Result<()> {
        if !self.lines {
            if !self.opened {
                out.extend_from_slice(b"[");
                out.extend_from_slice(self.newline.as_bytes());
            }
            out.extend_from_slice(self.newline.as_bytes());
            out.extend_from_slice(b"]");
            out.extend_from_slice(self.newline.as_bytes());
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Markdown
// ---------------------------------------------------------------------------

struct Markdown {
    spec: ExportSpec,
    newline: &'static str,
    wrote_header: bool,
}

impl Markdown {
    fn new(spec: &ExportSpec) -> Self {
        Self {
            spec: spec.clone(),
            newline: spec.line_ending.as_str(),
            wrote_header: false,
        }
    }

    fn cell(text: &str) -> String {
        text.replace('|', "\\|")
            .replace('\n', "<br>")
            .replace('\r', "")
    }
}

impl RowWriter for Markdown {
    fn begin(&mut self, columns: &[ColumnDesc], out: &mut Vec<u8>) -> Result<()> {
        if self.wrote_header {
            return Ok(());
        }
        self.wrote_header = true;

        let names = columns
            .iter()
            .map(|column| Self::cell(&column.name))
            .collect::<Vec<_>>();
        // Numeric columns are right aligned, which is what makes a rendered
        // table readable.
        let rules = columns
            .iter()
            .map(|column| if is_numeric(column) { "---:" } else { "---" })
            .collect::<Vec<_>>();

        out.extend_from_slice(format!("| {} |", names.join(" | ")).as_bytes());
        out.extend_from_slice(self.newline.as_bytes());
        out.extend_from_slice(format!("| {} |", rules.join(" | ")).as_bytes());
        out.extend_from_slice(self.newline.as_bytes());
        Ok(())
    }

    fn row(
        &mut self,
        columns: &[ColumnDesc],
        values: &[JsonValue],
        out: &mut Vec<u8>,
    ) -> Result<()> {
        let cells = values
            .iter()
            .enumerate()
            .map(
                |(index, value)| match render(value, &columns[index], &self.spec) {
                    None => self.spec.effective_null(),
                    Some(text) => Self::cell(&text),
                },
            )
            .collect::<Vec<_>>();
        out.extend_from_slice(format!("| {} |", cells.join(" | ")).as_bytes());
        out.extend_from_slice(self.newline.as_bytes());
        Ok(())
    }

    fn finish(&mut self, _out: &mut Vec<u8>) -> Result<()> {
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// HTML
// ---------------------------------------------------------------------------

struct Html {
    spec: ExportSpec,
    newline: &'static str,
    opened: bool,
}

impl Html {
    fn new(spec: &ExportSpec) -> Self {
        Self {
            spec: spec.clone(),
            newline: spec.line_ending.as_str(),
            opened: false,
        }
    }

    fn escape(text: &str) -> String {
        text.replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
            .replace('"', "&quot;")
    }
}

impl RowWriter for Html {
    fn begin(&mut self, columns: &[ColumnDesc], out: &mut Vec<u8>) -> Result<()> {
        if self.opened {
            return Ok(());
        }
        self.opened = true;

        let mut head = String::new();
        head.push_str("<!doctype html>\n<meta charset=\"utf-8\">\n");
        head.push_str("<style>\n");
        head.push_str(
            "table{border-collapse:collapse;font-family:ui-monospace,monospace;font-size:13px}\n",
        );
        head.push_str("th,td{border:1px solid #d0d7de;padding:4px 8px;text-align:left}\n");
        head.push_str("th{background:#f6f8fa;position:sticky;top:0}\n");
        head.push_str("td.n{text-align:right}\ntd.null{color:#8c959f;font-style:italic}\n");
        head.push_str("tr:nth-child(even){background:#fafbfc}\n");
        head.push_str("</style>\n<table>\n<thead><tr>");
        for column in columns {
            head.push_str(&format!("<th>{}</th>", Self::escape(&column.name)));
        }
        head.push_str("</tr></thead>\n<tbody>\n");

        out.extend_from_slice(head.as_bytes());
        Ok(())
    }

    fn row(
        &mut self,
        columns: &[ColumnDesc],
        values: &[JsonValue],
        out: &mut Vec<u8>,
    ) -> Result<()> {
        let mut line = String::from("<tr>");
        for (index, value) in values.iter().enumerate() {
            let column = &columns[index];
            match render(value, column, &self.spec) {
                None => line.push_str(&format!(
                    "<td class=\"null\">{}</td>",
                    Self::escape(&self.spec.effective_null())
                )),
                Some(text) => {
                    let class = if is_numeric(column) {
                        " class=\"n\""
                    } else {
                        ""
                    };
                    line.push_str(&format!("<td{}>{}</td>", class, Self::escape(&text)));
                }
            }
        }
        line.push_str("</tr>");

        out.extend_from_slice(line.as_bytes());
        out.extend_from_slice(self.newline.as_bytes());
        Ok(())
    }

    fn finish(&mut self, out: &mut Vec<u8>) -> Result<()> {
        out.extend_from_slice(b"</tbody>\n</table>\n");
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// XML
// ---------------------------------------------------------------------------

struct Xml {
    spec: ExportSpec,
    newline: &'static str,
    opened: bool,
}

impl Xml {
    fn new(spec: &ExportSpec) -> Self {
        Self {
            spec: spec.clone(),
            newline: spec.line_ending.as_str(),
            opened: false,
        }
    }

    fn escape(text: &str) -> String {
        text.replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
    }

    /// XML element names cannot start with a digit or contain spaces.
    fn tag(name: &str) -> String {
        let mut out = String::with_capacity(name.len());
        for (index, character) in name.chars().enumerate() {
            let valid = character.is_alphanumeric() || character == '_' || character == '-';
            if index == 0 && (character.is_numeric() || !valid) {
                out.push('_');
            }
            out.push(if valid { character } else { '_' });
        }
        if out.is_empty() {
            "column".to_string()
        } else {
            out
        }
    }
}

impl RowWriter for Xml {
    fn begin(&mut self, _columns: &[ColumnDesc], out: &mut Vec<u8>) -> Result<()> {
        if self.opened {
            return Ok(());
        }
        self.opened = true;
        out.extend_from_slice(b"<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
        out.extend_from_slice(self.newline.as_bytes());
        out.extend_from_slice(b"<rows>");
        out.extend_from_slice(self.newline.as_bytes());
        Ok(())
    }

    fn row(
        &mut self,
        columns: &[ColumnDesc],
        values: &[JsonValue],
        out: &mut Vec<u8>,
    ) -> Result<()> {
        let mut line = String::from("  <row>");
        for (index, value) in values.iter().enumerate() {
            let column = &columns[index];
            let tag = Self::tag(&column.name);
            match render(value, column, &self.spec) {
                // `xsi:nil` is how XML says absent, and it survives a round
                // trip where an empty element would not.
                None => line.push_str(&format!("<{tag} xsi:nil=\"true\"/>")),
                Some(text) => line.push_str(&format!("<{tag}>{}</{tag}>", Self::escape(&text))),
            }
        }
        line.push_str("</row>");

        out.extend_from_slice(line.as_bytes());
        out.extend_from_slice(self.newline.as_bytes());
        Ok(())
    }

    fn finish(&mut self, out: &mut Vec<u8>) -> Result<()> {
        out.extend_from_slice(b"</rows>");
        out.extend_from_slice(self.newline.as_bytes());
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// SQL
// ---------------------------------------------------------------------------

struct Sql {
    spec: ExportSpec,
    newline: &'static str,
    pending: Vec<String>,
    columns: Vec<String>,
    opened: bool,
}

impl Sql {
    fn new(spec: &ExportSpec) -> Self {
        Self {
            spec: spec.clone(),
            newline: spec.line_ending.as_str(),
            pending: Vec::new(),
            columns: Vec::new(),
            opened: false,
        }
    }

    fn dialect(&self) -> &str {
        self.spec.sql_dialect.as_deref().unwrap_or("postgres")
    }

    fn quote_ident(&self, name: &str) -> String {
        match self.dialect() {
            "mariadb" | "mysql" => format!("`{}`", name.replace('`', "``")),
            _ => format!("\"{}\"", name.replace('"', "\"\"")),
        }
    }

    fn quote_literal(&self, text: &str) -> String {
        match self.dialect() {
            // MySQL treats a backslash as an escape unless NO_BACKSLASH_ESCAPES
            // is set, so it has to be doubled or the value changes.
            "mariadb" | "mysql" => {
                format!("'{}'", text.replace('\\', "\\\\").replace('\'', "''"))
            }
            _ => format!("'{}'", text.replace('\'', "''")),
        }
    }

    fn target(&self) -> String {
        let name = self
            .spec
            .sql_table
            .clone()
            .or_else(|| self.spec.table.clone())
            .unwrap_or_else(|| "exported".to_string());
        match &self.spec.schema {
            Some(schema) if !schema.is_empty() && !name.contains('.') => {
                format!("{}.{}", self.quote_ident(schema), self.quote_ident(&name))
            }
            _ => {
                if name.contains('.') {
                    name
                } else {
                    self.quote_ident(&name)
                }
            }
        }
    }

    fn flush(&mut self, out: &mut Vec<u8>) {
        if self.pending.is_empty() {
            return;
        }

        let columns = self
            .columns
            .iter()
            .map(|name| self.quote_ident(name))
            .collect::<Vec<_>>()
            .join(", ");

        let verb = match (self.spec.sql_mode, self.dialect()) {
            (SqlMode::Replace, "mariadb") | (SqlMode::Replace, "mysql") => "replace into",
            (SqlMode::Ignore, "mariadb") | (SqlMode::Ignore, "mysql") => "insert ignore into",
            _ => "insert into",
        };

        let mut statement = format!(
            "{verb} {} ({columns}) values{}{}",
            self.target(),
            self.newline,
            self.pending.join(&format!(",{}", self.newline))
        );

        match (self.spec.sql_mode, self.dialect()) {
            (SqlMode::Upsert, "mariadb") | (SqlMode::Upsert, "mysql") => {
                let keys = &self.spec.sql_key_columns;
                let assignments = self
                    .columns
                    .iter()
                    .filter(|name| !keys.iter().any(|key| key == *name))
                    .map(|name| {
                        let quoted = self.quote_ident(name);
                        format!("{quoted} = values({quoted})")
                    })
                    .collect::<Vec<_>>()
                    .join(", ");
                statement.push_str(&format!(
                    "{}on duplicate key update {assignments}",
                    self.newline
                ));
            }
            (SqlMode::Upsert, _) => {
                let keys = &self.spec.sql_key_columns;
                let assignments = self
                    .columns
                    .iter()
                    .filter(|name| !keys.iter().any(|key| key == *name))
                    .map(|name| {
                        let quoted = self.quote_ident(name);
                        format!("{quoted} = excluded.{quoted}")
                    })
                    .collect::<Vec<_>>()
                    .join(", ");

                // Without a key the conflict target is unknown, so it is left
                // as a comment for the user rather than guessed at.
                let target = if keys.is_empty() {
                    "/* key columns */".to_string()
                } else {
                    keys.iter()
                        .map(|name| self.quote_ident(name))
                        .collect::<Vec<_>>()
                        .join(", ")
                };
                statement.push_str(&format!(
                    "{}on conflict ({target}) do update set {assignments}",
                    self.newline
                ));
            }
            (SqlMode::Ignore, _) => {
                statement.push_str(&format!("{}on conflict do nothing", self.newline));
            }
            _ => {}
        }

        statement.push(';');
        out.extend_from_slice(statement.as_bytes());
        out.extend_from_slice(self.newline.as_bytes());
        self.pending.clear();
    }
}

impl RowWriter for Sql {
    fn begin(&mut self, columns: &[ColumnDesc], out: &mut Vec<u8>) -> Result<()> {
        if self.opened {
            return Ok(());
        }
        self.opened = true;
        self.columns = columns.iter().map(|column| column.name.clone()).collect();

        if self.spec.sql_transaction {
            out.extend_from_slice(b"begin;");
            out.extend_from_slice(self.newline.as_bytes());
        }
        Ok(())
    }

    fn row(
        &mut self,
        columns: &[ColumnDesc],
        values: &[JsonValue],
        out: &mut Vec<u8>,
    ) -> Result<()> {
        let literals = values
            .iter()
            .enumerate()
            .map(|(index, value)| {
                let column = &columns[index];
                match render(value, column, &self.spec) {
                    None => "null".to_string(),
                    Some(text) => match column.class {
                        // A number written as a literal keeps its precision;
                        // quoting it would make the target cast it back.
                        ValueClass::Number if text.parse::<f64>().is_ok() => text,
                        ValueClass::Bool if matches!(text.as_str(), "true" | "false") => text,
                        _ => self.quote_literal(&text),
                    },
                }
            })
            .collect::<Vec<_>>();

        self.pending.push(format!("  ({})", literals.join(", ")));
        if self.pending.len() >= self.spec.sql_batch.max(1) {
            self.flush(out);
        }
        Ok(())
    }

    fn finish(&mut self, out: &mut Vec<u8>) -> Result<()> {
        self.flush(out);
        if self.spec.sql_transaction {
            out.extend_from_slice(b"commit;");
            out.extend_from_slice(self.newline.as_bytes());
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Aligned text
// ---------------------------------------------------------------------------

/// The grid as it looks on screen. Buffers, because column widths are only
/// known once every row has been seen.
struct Text {
    spec: ExportSpec,
    newline: &'static str,
    columns: Vec<String>,
    rows: Vec<Vec<String>>,
}

impl Text {
    fn new(spec: &ExportSpec) -> Self {
        Self {
            spec: spec.clone(),
            newline: spec.line_ending.as_str(),
            columns: Vec::new(),
            rows: Vec::new(),
        }
    }

    fn width(text: &str) -> usize {
        text.chars().count()
    }
}

impl RowWriter for Text {
    fn begin(&mut self, columns: &[ColumnDesc], _out: &mut Vec<u8>) -> Result<()> {
        self.columns = columns.iter().map(|column| column.name.clone()).collect();
        Ok(())
    }

    fn row(
        &mut self,
        columns: &[ColumnDesc],
        values: &[JsonValue],
        _out: &mut Vec<u8>,
    ) -> Result<()> {
        self.rows.push(
            values
                .iter()
                .enumerate()
                .map(|(index, value)| {
                    render(value, &columns[index], &self.spec)
                        .unwrap_or_else(|| self.spec.effective_null())
                        .replace('\n', "\\n")
                        .replace('\t', "\\t")
                })
                .collect(),
        );
        Ok(())
    }

    fn finish(&mut self, out: &mut Vec<u8>) -> Result<()> {
        let mut widths = self
            .columns
            .iter()
            .map(|name| Self::width(name))
            .collect::<Vec<_>>();
        for row in &self.rows {
            for (index, cell) in row.iter().enumerate() {
                if index < widths.len() {
                    widths[index] = widths[index].max(Self::width(cell));
                }
            }
        }

        let header = self
            .columns
            .iter()
            .enumerate()
            .map(|(index, name)| format!("{name:<width$}", width = widths[index]))
            .collect::<Vec<_>>()
            .join(" | ");
        let rule = widths
            .iter()
            .map(|width| "-".repeat(*width))
            .collect::<Vec<_>>()
            .join("-+-");

        out.extend_from_slice(header.as_bytes());
        out.extend_from_slice(self.newline.as_bytes());
        out.extend_from_slice(rule.as_bytes());
        out.extend_from_slice(self.newline.as_bytes());

        for row in &self.rows {
            let line = row
                .iter()
                .enumerate()
                .map(|(index, cell)| {
                    let width = widths.get(index).copied().unwrap_or(0);
                    format!("{cell:<width$}")
                })
                .collect::<Vec<_>>()
                .join(" | ");
            out.extend_from_slice(line.trim_end().as_bytes());
            out.extend_from_slice(self.newline.as_bytes());
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::ValueClass;
    use serde_json::json;

    fn spec(format: &str) -> ExportSpec {
        serde_json::from_value(json!({
            "format": format,
            "destination": "/tmp/out",
            "sql": "select 1",
        }))
        .unwrap()
    }

    fn columns() -> Vec<ColumnDesc> {
        vec![
            ColumnDesc::new("id", "int", ValueClass::Number),
            ColumnDesc::new("name", "text", ValueClass::Text),
            ColumnDesc::new("note", "text", ValueClass::Text),
        ]
    }

    fn write(settings: &ExportSpec, rows: Vec<Vec<JsonValue>>) -> String {
        let columns = columns();
        let mut writer = make(settings, &columns);
        let mut out = Vec::new();
        writer.begin(&columns, &mut out).unwrap();
        for row in &rows {
            writer.row(&columns, row, &mut out).unwrap();
        }
        writer.finish(&mut out).unwrap();
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn csv_keeps_null_and_empty_apart() {
        let mut settings = spec("csv");
        settings.null_as = Some("\\N".to_string());
        let output = write(
            &settings,
            vec![vec![json!("1"), json!(""), JsonValue::Null]],
        );
        assert_eq!(output, "id,name,note\n1,,\\N\n");
    }

    #[test]
    fn csv_quotes_only_what_needs_it() {
        let output = write(
            &spec("csv"),
            vec![vec![json!("1"), json!("a,b"), json!("plain")]],
        );
        assert!(output.contains("\"a,b\""));
        assert!(output.contains(",plain"));
    }

    #[test]
    fn csv_doubles_an_embedded_quote() {
        let output = write(
            &spec("csv"),
            vec![vec![json!("1"), json!("say \"hi\""), json!("x")]],
        );
        assert!(output.contains("\"say \"\"hi\"\"\""));
    }

    #[test]
    fn csv_can_backslash_escape_instead() {
        let mut settings = spec("csv");
        settings.escape = Escape::Backslash;
        let output = write(
            &settings,
            vec![vec![json!("1"), json!("say \"hi\""), json!("x")]],
        );
        assert!(output.contains("\"say \\\"hi\\\"\""));
    }

    #[test]
    fn csv_quoting_all_still_leaves_null_bare() {
        let mut settings = spec("csv");
        settings.quoting = Quoting::All;
        settings.null_as = Some(String::new());
        let output = write(
            &settings,
            vec![vec![json!("1"), json!(""), JsonValue::Null]],
        );
        // An empty string is `""`; NULL is nothing at all.
        assert_eq!(output.lines().nth(1).unwrap(), "\"1\",\"\",");
    }

    #[test]
    fn csv_non_numeric_quoting_leaves_numbers_alone() {
        let mut settings = spec("csv");
        settings.quoting = Quoting::NonNumeric;
        let output = write(&settings, vec![vec![json!("42"), json!("x"), json!("y")]]);
        assert_eq!(output.lines().nth(1).unwrap(), "42,\"x\",\"y\"");
    }

    #[test]
    fn csv_writes_a_bom_and_crlf_for_excel() {
        let mut settings = spec("csv");
        settings.bom = true;
        settings.line_ending = crate::export::LineEnding::Crlf;
        let output = write(&settings, vec![vec![json!("1"), json!("Łódź"), json!("x")]]);
        assert!(output.starts_with('\u{feff}'));
        assert!(output.contains("\r\n"));
        assert!(output.contains("Łódź"));
    }

    #[test]
    fn csv_moves_the_decimal_separator() {
        let mut settings = spec("csv");
        settings.decimal_separator = Some(",".to_string());
        let output = write(&settings, vec![vec![json!("1.5"), json!("x"), json!("y")]]);
        // The delimiter became a semicolon so the comma decimal is unambiguous.
        assert_eq!(output.lines().nth(1).unwrap(), "1,5;x;y");
    }

    #[test]
    fn tsv_uses_tabs() {
        let output = write(&spec("tsv"), vec![vec![json!("1"), json!("a"), json!("b")]]);
        assert_eq!(output.lines().nth(1).unwrap(), "1\ta\tb");
    }

    #[test]
    fn json_emits_an_array_of_objects() {
        let output = write(
            &spec("json"),
            vec![vec![json!("1"), json!("a"), JsonValue::Null]],
        );
        let parsed: JsonValue = serde_json::from_str(&output).unwrap();
        assert_eq!(parsed[0]["id"], json!(1), "a numeric column stays numeric");
        assert_eq!(parsed[0]["name"], json!("a"));
        assert_eq!(parsed[0]["note"], JsonValue::Null);
    }

    #[test]
    fn json_of_an_empty_result_is_still_valid() {
        let output = write(&spec("json"), vec![]);
        let parsed: JsonValue = serde_json::from_str(&output).unwrap();
        assert_eq!(parsed, json!([]));
    }

    #[test]
    fn jsonl_emits_one_object_per_line() {
        let output = write(
            &spec("jsonl"),
            vec![
                vec![json!("1"), json!("a"), json!("x")],
                vec![json!("2"), json!("b"), json!("y")],
            ],
        );
        assert_eq!(output.lines().count(), 2);
        for line in output.lines() {
            serde_json::from_str::<JsonValue>(line).unwrap();
        }
    }

    #[test]
    fn json_inlines_a_json_column_instead_of_escaping_it() {
        let columns = vec![ColumnDesc::new("payload", "jsonb", ValueClass::Json)];
        let settings = spec("jsonl");
        let mut writer = make(&settings, &columns);
        let mut out = Vec::new();
        writer.begin(&columns, &mut out).unwrap();
        writer
            .row(&columns, &[json!("{\"k\":[1,2]}")], &mut out)
            .unwrap();
        writer.finish(&mut out).unwrap();

        let parsed: JsonValue =
            serde_json::from_str(String::from_utf8(out).unwrap().trim()).unwrap();
        assert_eq!(
            parsed["payload"]["k"],
            json!([1, 2]),
            "not a string of JSON"
        );
    }

    #[test]
    fn json_can_keep_a_json_column_as_a_string() {
        let columns = vec![ColumnDesc::new("payload", "jsonb", ValueClass::Json)];
        let mut settings = spec("jsonl");
        settings.json_mode = JsonMode::String;
        let mut writer = make(&settings, &columns);
        let mut out = Vec::new();
        writer.begin(&columns, &mut out).unwrap();
        writer
            .row(&columns, &[json!("{\"k\":1}")], &mut out)
            .unwrap();
        writer.finish(&mut out).unwrap();

        let parsed: JsonValue =
            serde_json::from_str(String::from_utf8(out).unwrap().trim()).unwrap();
        assert!(parsed["payload"].is_string());
    }

    #[test]
    fn markdown_right_aligns_numbers_and_escapes_pipes() {
        let output = write(
            &spec("markdown"),
            vec![vec![json!("1"), json!("a|b"), json!("two\nlines")]],
        );
        assert!(output.contains("| ---: | --- | --- |"));
        assert!(output.contains("a\\|b"));
        assert!(output.contains("two<br>lines"));
    }

    #[test]
    fn html_escapes_and_marks_nulls() {
        let output = write(
            &spec("html"),
            vec![vec![json!("1"), json!("<script>"), JsonValue::Null]],
        );
        assert!(output.contains("&lt;script&gt;"));
        assert!(output.contains("class=\"null\""));
        assert!(output.contains("<td class=\"n\">1</td>"));
    }

    #[test]
    fn xml_uses_nil_for_null_and_sanitises_tags() {
        let columns = vec![ColumnDesc::new("2 odd name", "text", ValueClass::Text)];
        let settings = spec("xml");
        let mut writer = make(&settings, &columns);
        let mut out = Vec::new();
        writer.begin(&columns, &mut out).unwrap();
        writer.row(&columns, &[JsonValue::Null], &mut out).unwrap();
        writer.row(&columns, &[json!("a & b")], &mut out).unwrap();
        writer.finish(&mut out).unwrap();

        let output = String::from_utf8(out).unwrap();
        assert!(output.contains("xsi:nil=\"true\""));
        assert!(output.contains("a &amp; b"));
        assert!(!output.contains("<2 odd name>"));
    }

    #[test]
    fn sql_batches_rows_into_multi_row_inserts() {
        let mut settings = spec("sql");
        settings.sql_table = Some("customers".to_string());
        settings.sql_batch = 2;
        let output = write(
            &settings,
            vec![
                vec![json!("1"), json!("a"), JsonValue::Null],
                vec![json!("2"), json!("b"), json!("x")],
                vec![json!("3"), json!("c"), json!("y")],
            ],
        );

        assert_eq!(output.matches("insert into").count(), 2);
        assert!(output.contains("(1, 'a', null)"));
    }

    #[test]
    fn sql_quotes_for_the_target_dialect() {
        let mut settings = spec("sql");
        settings.sql_table = Some("customers".to_string());
        settings.sql_dialect = Some("mariadb".to_string());
        let output = write(
            &settings,
            vec![vec![json!("1"), json!("back\\slash"), json!("x")]],
        );
        assert!(output.contains("`customers`"));
        assert!(
            output.contains("back\\\\slash"),
            "MySQL treats a backslash as an escape"
        );
    }

    #[test]
    fn sql_can_upsert() {
        let mut settings = spec("sql");
        settings.sql_table = Some("customers".to_string());
        settings.sql_mode = SqlMode::Upsert;
        settings.sql_dialect = Some("mariadb".to_string());
        let output = write(&settings, vec![vec![json!("1"), json!("a"), json!("x")]]);
        assert!(output.contains("on duplicate key update"));
        assert!(output.contains("`name` = values(`name`)"));
    }

    #[test]
    fn sql_wraps_in_a_transaction_when_asked() {
        let mut settings = spec("sql");
        settings.sql_transaction = true;
        settings.sql_table = Some("t".to_string());
        let output = write(&settings, vec![vec![json!("1"), json!("a"), json!("x")]]);
        assert!(output.starts_with("begin;"));
        assert!(output.trim_end().ends_with("commit;"));
    }

    #[test]
    fn text_aligns_the_grid() {
        let output = write(
            &spec("text"),
            vec![
                vec![json!("1"), json!("short"), json!("x")],
                vec![json!("200"), json!("much longer"), json!("y")],
            ],
        );
        let lines: Vec<&str> = output.lines().collect();
        assert!(lines[1].contains("-+-"));
        assert_eq!(
            lines[2].find('|'),
            lines[3].find('|'),
            "columns must line up"
        );
    }

    #[test]
    fn binary_can_be_hex_or_base64_or_dropped() {
        let columns = [ColumnDesc::new("blob", "bytea", ValueClass::Binary)];
        let value = json!("\\x48690a");

        for (mode, expected) in [
            (BinaryMode::Hex, "\\x48690a"),
            (BinaryMode::Base64, "SGkK"),
            (BinaryMode::Omit, ""),
        ] {
            let mut settings = spec("csv");
            settings.binary = mode;
            let rendered = render(&value, &columns[0], &settings).unwrap();
            assert_eq!(rendered, expected, "binary mode {mode:?}");
        }
    }
}

#[cfg(test)]
mod json_and_upsert_tests {
    use super::*;
    use crate::protocol::ValueClass;
    use serde_json::json;

    fn spec(format: &str) -> ExportSpec {
        serde_json::from_value(json!({
            "format": format,
            "destination": "/tmp/out",
            "sql": "select 1",
        }))
        .unwrap()
    }

    #[test]
    fn a_text_column_can_be_declared_as_json() {
        // SQLite has no JSON type, so the caller names the column instead of
        // the exporter guessing from a leading brace.
        let columns = vec![ColumnDesc::new("payload", "text", ValueClass::Text)];
        let mut settings = spec("jsonl");
        settings.json_columns = vec!["payload".to_string()];

        let mut writer = make(&settings, &columns);
        let mut out = Vec::new();
        writer.begin(&columns, &mut out).unwrap();
        writer
            .row(&columns, &[json!("{\"k\":[1,2]}")], &mut out)
            .unwrap();
        writer.finish(&mut out).unwrap();

        let parsed: JsonValue =
            serde_json::from_str(String::from_utf8(out).unwrap().trim()).unwrap();
        assert_eq!(parsed["payload"]["k"], json!([1, 2]));
    }

    #[test]
    fn an_undeclared_text_column_stays_text() {
        let columns = vec![ColumnDesc::new("note", "text", ValueClass::Text)];
        let settings = spec("jsonl");
        let mut writer = make(&settings, &columns);
        let mut out = Vec::new();
        writer.begin(&columns, &mut out).unwrap();
        writer
            .row(&columns, &[json!("{not really json")], &mut out)
            .unwrap();
        writer.finish(&mut out).unwrap();

        let parsed: JsonValue =
            serde_json::from_str(String::from_utf8(out).unwrap().trim()).unwrap();
        assert!(parsed["note"].is_string());
    }

    #[test]
    fn upsert_uses_the_declared_key_and_excludes_it_from_the_update() {
        let columns = vec![
            ColumnDesc::new("id", "int", ValueClass::Number),
            ColumnDesc::new("name", "text", ValueClass::Text),
        ];
        let mut settings = spec("sql");
        settings.sql_table = Some("customers".to_string());
        settings.sql_mode = SqlMode::Upsert;
        settings.sql_key_columns = vec!["id".to_string()];

        let mut writer = make(&settings, &columns);
        let mut out = Vec::new();
        writer.begin(&columns, &mut out).unwrap();
        writer
            .row(&columns, &[json!("1"), json!("a")], &mut out)
            .unwrap();
        writer.finish(&mut out).unwrap();

        let output = String::from_utf8(out).unwrap();
        assert!(output.contains(r#"on conflict ("id") do update set"#));
        assert!(output.contains(r#""name" = excluded."name""#));
        assert!(
            !output.contains(r#""id" = excluded."id""#),
            "the key must not be reassigned to itself"
        );
    }
}
