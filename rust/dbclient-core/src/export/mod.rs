//! Export.
//!
//! Every database client can write a CSV. What they get wrong is everything
//! around it, so this is deliberately opinionated about the details other tools
//! leave to a checkbox nobody finds:
//!
//! * **NULL is not an empty string.** Both render as nothing in CSV, which
//!   silently destroys the distinction on the way out and again on the way
//!   back. The sentinel is configurable and recorded in the manifest, so a
//!   round trip is possible and an exported file says what it means.
//! * **Excel is a real target.** A UTF-8 BOM, CRLF line endings and a
//!   semicolon delimiter are what make a file with `Łódź` in it open correctly
//!   in a Polish or German locale, and the `excel` preset sets all three.
//! * **Memory stays flat.** Rows are streamed from a cursor and written as they
//!   arrive, so exporting more rows than fit in RAM is ordinary rather than
//!   impossible.
//! * **An export is reproducible.** The manifest records the statement, the
//!   connection, the row count, the column types, the settings and a SHA-256 of
//!   each file, so "what exactly did you send me" has an answer.
//! * **Large exports split.** By row count or by the value of a column, which
//!   is how per-day and per-tenant files get made without a shell loop.
//! * **Sensitive columns can be masked** at the moment of export, which is the
//!   moment you actually need it.

pub mod checksum;
pub mod writers;
pub mod xlsx;
pub mod zip;

use crate::protocol::ColumnDesc;
use crate::session::DbSession;
use anyhow::{anyhow, Context, Result};
use checksum::{hex, Sha256};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value as JsonValue};
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use writers::RowWriter;

// ---------------------------------------------------------------------------
// Specification
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Format {
    Csv,
    Tsv,
    Json,
    Jsonl,
    Markdown,
    Html,
    Xml,
    Sql,
    Xlsx,
    Text,
}

impl Format {
    pub fn extension(self) -> &'static str {
        match self {
            Format::Csv => "csv",
            Format::Tsv => "tsv",
            Format::Json => "json",
            Format::Jsonl => "jsonl",
            Format::Markdown => "md",
            Format::Html => "html",
            Format::Xml => "xml",
            Format::Sql => "sql",
            Format::Xlsx => "xlsx",
            Format::Text => "txt",
        }
    }

    /// XLSX is a container, so it cannot be written incrementally to a stream.
    pub fn buffers(self) -> bool {
        matches!(self, Format::Xlsx)
    }
}

/// When to put quotes around a delimited field.
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Quoting {
    /// Only when the field would otherwise be ambiguous.
    #[default]
    Minimal,
    /// Every field, which some importers insist on.
    All,
    /// Everything except numbers, so a spreadsheet keeps them numeric.
    NonNumeric,
    /// Never; only safe when the data cannot contain the delimiter.
    None,
}

/// How an embedded quote character is escaped.
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Escape {
    /// `""`, as RFC 4180 specifies.
    #[default]
    Double,
    /// `\"`, as MySQL and many unix tools expect.
    Backslash,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum LineEnding {
    #[default]
    Lf,
    Crlf,
}

impl LineEnding {
    pub fn as_str(self) -> &'static str {
        match self {
            LineEnding::Lf => "\n",
            LineEnding::Crlf => "\r\n",
        }
    }
}

/// What to do with a binary column.
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum BinaryMode {
    /// `\x0a1b…`, which is how the grid shows it and how PostgreSQL reads it.
    #[default]
    Hex,
    Base64,
    /// Leave the cell empty; useful when the blobs are large and irrelevant.
    Omit,
}

/// Whether a JSON column is embedded as JSON or as a string containing JSON.
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum JsonMode {
    /// Embed it, so the output is one document rather than a document holding
    /// escaped documents. This is the thing most tools get wrong.
    #[default]
    Inline,
    /// Keep it as a string, for consumers that expect that.
    String,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SqlMode {
    #[default]
    Insert,
    /// `insert … on conflict/duplicate key update`.
    Upsert,
    /// `insert … ` that ignores an existing row.
    Ignore,
    Replace,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Compression {
    Gzip,
}

fn default_batch() -> usize {
    2_000
}
fn default_true() -> bool {
    true
}
fn default_sql_batch() -> usize {
    100
}
fn default_redaction() -> String {
    "***".to_string()
}
fn default_sheet() -> String {
    "data".to_string()
}

/// Everything an export needs to know.
#[derive(Clone, Debug, Deserialize)]
pub struct ExportSpec {
    pub format: Format,
    /// A file path, or a directory when the export is partitioned.
    pub destination: String,

    /// Exactly one of these two describes what to export.
    #[serde(default)]
    pub sql: Option<String>,
    #[serde(default)]
    pub table: Option<String>,
    #[serde(default)]
    pub schema: Option<String>,
    #[serde(default)]
    pub filter: Option<String>,
    #[serde(default)]
    pub order: Option<String>,

    #[serde(default)]
    pub limit: Option<u64>,
    #[serde(default = "default_batch")]
    pub batch_size: usize,

    // Delimited text.
    #[serde(default)]
    pub delimiter: Option<String>,
    #[serde(default)]
    pub quote: Option<String>,
    #[serde(default)]
    pub quoting: Quoting,
    #[serde(default)]
    pub escape: Escape,
    #[serde(default = "default_true")]
    pub header: bool,
    #[serde(default)]
    pub line_ending: LineEnding,
    #[serde(default)]
    pub bom: bool,
    /// A locale that writes `1,5` needs the delimiter to move out of the way.
    #[serde(default)]
    pub decimal_separator: Option<String>,

    // Fidelity.
    #[serde(default)]
    pub null_as: Option<String>,
    #[serde(default)]
    pub binary: BinaryMode,
    #[serde(default)]
    pub json_mode: JsonMode,
    /// Columns holding JSON that the backend does not type as JSON.
    ///
    /// SQLite has no JSON type and a text column full of documents looks like
    /// any other text column. Guessing from the content would be wrong — a
    /// column really can hold text that starts with a brace — so the caller
    /// names them.
    #[serde(default)]
    pub json_columns: Vec<String>,

    // SQL output.
    #[serde(default)]
    pub sql_mode: SqlMode,
    #[serde(default)]
    pub sql_table: Option<String>,
    #[serde(default = "default_sql_batch")]
    pub sql_batch: usize,
    #[serde(default)]
    pub sql_transaction: bool,
    #[serde(default)]
    pub sql_dialect: Option<String>,
    /// Conflict target for an upsert. Without it PostgreSQL has nothing to key
    /// on and the generated statement cannot run.
    #[serde(default)]
    pub sql_key_columns: Vec<String>,

    // Shaping.
    #[serde(default)]
    pub columns: Option<Vec<String>>,
    #[serde(default)]
    pub redact: Vec<String>,
    #[serde(default = "default_redaction")]
    pub redact_with: String,

    // Output.
    #[serde(default)]
    pub compress: Option<Compression>,
    #[serde(default)]
    pub partition_rows: Option<u64>,
    #[serde(default)]
    pub partition_by: Option<String>,
    #[serde(default = "default_true")]
    pub manifest: bool,
    #[serde(default = "default_true")]
    pub checksum: bool,
    #[serde(default)]
    pub overwrite: bool,
    #[serde(default = "default_sheet")]
    pub sheet_name: String,

    /// Render to memory and return the first lines instead of writing files.
    #[serde(default)]
    pub preview: bool,
    #[serde(default)]
    pub preview_rows: Option<u64>,
}

impl ExportSpec {
    /// The delimiter this format and locale imply.
    pub fn effective_delimiter(&self) -> String {
        if let Some(delimiter) = &self.delimiter {
            return delimiter.clone();
        }
        match self.format {
            Format::Tsv => "\t".to_string(),
            // A comma decimal separator collides with a comma delimiter, which
            // is why Excel itself switches to a semicolon in those locales.
            _ => {
                if self.decimal_separator.as_deref() == Some(",") {
                    ";".to_string()
                } else {
                    ",".to_string()
                }
            }
        }
    }

    pub fn effective_quote(&self) -> char {
        self.quote
            .as_ref()
            .and_then(|value| value.chars().next())
            .unwrap_or('"')
    }

    pub fn effective_null(&self) -> String {
        self.null_as.clone().unwrap_or_default()
    }

    /// Whether a column should be treated as JSON, by type or by name.
    pub fn treats_as_json(&self, column: &ColumnDesc) -> bool {
        column.class == crate::protocol::ValueClass::Json
            || self.json_columns.iter().any(|name| name == &column.name)
    }

    /// The statement to run.
    pub fn build_sql(&self, dialect: &str) -> Result<String> {
        let quote_ident = |name: &str| quote_identifier(dialect, name);
        if let Some(sql) = &self.sql {
            if sql.trim().is_empty() {
                return Err(anyhow!("the export has no statement to run"));
            }
            return Ok(sql.trim().trim_end_matches(';').to_string());
        }

        let table = self
            .table
            .as_ref()
            .ok_or_else(|| anyhow!("the export needs either `sql` or `table`"))?;

        let mut sql = match &self.schema {
            Some(schema) if !schema.is_empty() => {
                format!(
                    "select * from {}.{}",
                    quote_ident(schema),
                    quote_ident(table)
                )
            }
            _ => format!("select * from {}", quote_ident(table)),
        };

        if let Some(filter) = self
            .filter
            .as_deref()
            .filter(|value| !value.trim().is_empty())
        {
            crate::session::validate_filter(filter)?;
            sql.push_str(&format!(" where {filter}"));
        }
        if let Some(order) = self
            .order
            .as_deref()
            .filter(|value| !value.trim().is_empty())
        {
            sql.push_str(&format!(" order by {order}"));
        }
        Ok(sql)
    }
}

// ---------------------------------------------------------------------------
// Outcome
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
pub struct FileReport {
    pub path: String,
    pub rows: u64,
    pub bytes: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub partition: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ExportOutcome {
    pub rows: u64,
    pub files: Vec<FileReport>,
    pub elapsed_ms: u64,
    pub format: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub manifest: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<String>,
}

// ---------------------------------------------------------------------------
// Sink
// ---------------------------------------------------------------------------

/// One output file: counts bytes, hashes as it writes, and optionally gzips.
struct Sink {
    path: PathBuf,
    writer: Box<dyn Write>,
    hasher: Option<Sha256>,
    bytes: u64,
    rows: u64,
    partition: Option<String>,
}

impl Sink {
    fn new(path: &Path, spec: &ExportSpec, partition: Option<String>) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("could not create {}", parent.display()))?;
        }
        if path.exists() && !spec.overwrite {
            return Err(anyhow!(
                "{} already exists; set `overwrite` to replace it",
                path.display()
            ));
        }

        let file =
            File::create(path).with_context(|| format!("could not write to {}", path.display()))?;
        let writer: Box<dyn Write> = match spec.compress {
            Some(Compression::Gzip) => Box::new(flate2::write::GzEncoder::new(
                BufWriter::new(file),
                flate2::Compression::default(),
            )),
            None => Box::new(BufWriter::new(file)),
        };

        Ok(Self {
            path: path.to_path_buf(),
            writer,
            hasher: spec.checksum.then(Sha256::new),
            bytes: 0,
            rows: 0,
            partition,
        })
    }

    fn write(&mut self, data: &[u8]) -> Result<()> {
        // The hash covers the bytes as written, before compression, so it
        // describes the content rather than the container.
        if let Some(hasher) = self.hasher.as_mut() {
            hasher.update(data);
        }
        self.bytes += data.len() as u64;
        self.writer.write_all(data)?;
        Ok(())
    }

    fn finish(mut self) -> Result<FileReport> {
        self.writer.flush()?;
        drop(self.writer);
        Ok(FileReport {
            path: self.path.display().to_string(),
            rows: self.rows,
            bytes: self.bytes,
            sha256: self.hasher.map(|hasher| hex(&hasher.finish())),
            partition: self.partition,
        })
    }
}

/// Where the bytes of one partition go.
enum Target {
    File(Sink),
    Memory {
        buffer: Vec<u8>,
        rows: u64,
        partition: Option<String>,
    },
}

impl Target {
    fn write(&mut self, data: &[u8]) -> Result<()> {
        match self {
            Target::File(sink) => sink.write(data),
            Target::Memory { buffer, .. } => {
                buffer.extend_from_slice(data);
                Ok(())
            }
        }
    }

    fn count_row(&mut self) {
        match self {
            Target::File(sink) => sink.rows += 1,
            Target::Memory { rows, .. } => *rows += 1,
        }
    }
}

// ---------------------------------------------------------------------------
// Running an export
// ---------------------------------------------------------------------------

/// A partition being written: its writer and its destination.
struct Partition {
    writer: Box<dyn RowWriter>,
    target: Target,
    started: bool,
}

/// Turn a partition value into something that can be a file name.
fn slug(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for character in value.chars() {
        if character.is_alphanumeric() || character == '-' || character == '_' || character == '.' {
            out.push(character);
        } else {
            out.push('-');
        }
    }
    let trimmed = out.trim_matches('-').to_string();
    if trimmed.is_empty() {
        "null".to_string()
    } else {
        trimmed.chars().take(60).collect()
    }
}

/// Build the path for a partition of an export.
fn partition_path(spec: &ExportSpec, key: Option<&str>, index: usize) -> PathBuf {
    let base = PathBuf::from(shellexpand(&spec.destination));
    let extension = spec.format.extension();
    let suffix = match spec.compress {
        Some(Compression::Gzip) => ".gz",
        None => "",
    };

    if key.is_none() && index == 0 && spec.partition_rows.is_none() {
        // A single unpartitioned file uses the destination as given, adding an
        // extension only when it has none.
        if base.extension().is_some() || spec.compress.is_some() {
            let mut path = base.clone();
            if spec.compress.is_some() && !base.to_string_lossy().ends_with(suffix) {
                path = PathBuf::from(format!("{}{}", base.display(), suffix));
            }
            return path;
        }
        return PathBuf::from(format!("{}.{}", base.display(), extension));
    }

    // Partitioned: the destination is a directory or a stem.
    let stem = base
        .file_stem()
        .map(|value| value.to_string_lossy().to_string())
        .unwrap_or_else(|| "export".to_string());
    let parent = if base.extension().is_some() {
        base.parent().map(Path::to_path_buf).unwrap_or_default()
    } else {
        base.clone()
    };

    let name = match key {
        Some(key) => format!("{stem}-{}.{extension}{suffix}", slug(key)),
        None => format!("{stem}-{:04}.{extension}{suffix}", index + 1),
    };
    parent.join(name)
}

/// Quote an identifier for a dialect.
pub fn quote_identifier(dialect: &str, name: &str) -> String {
    match dialect {
        "mariadb" | "mysql" => format!("`{}`", name.replace('`', "``")),
        _ => format!("\"{}\"", name.replace('"', "\"\"")),
    }
}

fn shellexpand(path: &str) -> String {
    if let Some(rest) = path.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return format!("{home}/{rest}");
        }
    }
    path.to_string()
}

/// Run an export against a session.
pub fn run(
    session: &mut dyn DbSession,
    spec: &ExportSpec,
    mut progress: impl FnMut(u64),
) -> Result<ExportOutcome> {
    let started = std::time::Instant::now();
    let sql = spec.build_sql(session.dialect())?;
    let mut warnings = Vec::new();

    if spec.sql_mode == SqlMode::Upsert
        && spec.sql_key_columns.is_empty()
        && !matches!(session.dialect(), "mariadb" | "mysql")
    {
        warnings.push(
            "upsert without `sql_key_columns`: the ON CONFLICT target is left as a comment for you to fill in"
                .to_string(),
        );
    }

    if spec.format.buffers() && spec.partition_rows.is_none() && spec.partition_by.is_none() {
        // A spreadsheet has to be assembled before it can be written, so a
        // huge one is a memory problem; say so rather than let it surprise.
        warnings.push(
            "XLSX is assembled in memory; partition or use CSV for very large exports".to_string(),
        );
    }

    let preview_limit = spec.preview_rows.unwrap_or(20);
    let mut partitions: BTreeMap<String, Partition> = BTreeMap::new();
    let mut order: Vec<String> = Vec::new();
    let mut columns_used: Vec<ColumnDesc> = Vec::new();
    let mut projection: Vec<usize> = Vec::new();
    let mut redacted: Vec<bool> = Vec::new();
    let mut written = 0u64;
    let mut partition_index = 0usize;
    let mut rows_in_current = 0u64;
    let mut current_key = String::new();

    let limit = spec.limit;

    let mut sink_error: Option<anyhow::Error> = None;

    let total = session.stream_query(&sql, spec.batch_size, &mut |columns, rows| {
        // First batch: work out the projection and the redaction mask.
        if columns_used.is_empty() {
            let (indices, chosen) = project(columns, spec.columns.as_deref())?;
            projection = indices;
            columns_used = chosen;
            redacted = columns_used
                .iter()
                .map(|column| spec.redact.iter().any(|name| name == &column.name))
                .collect();
        }

        for row in rows {
            if let Some(limit) = limit {
                if written >= limit {
                    return Ok(false);
                }
            }
            if spec.preview && written >= preview_limit {
                return Ok(false);
            }

            let values = projection
                .iter()
                .enumerate()
                .map(|(position, index)| {
                    if redacted[position] {
                        JsonValue::String(spec.redact_with.clone())
                    } else {
                        row.get(*index).cloned().unwrap_or(JsonValue::Null)
                    }
                })
                .collect::<Vec<_>>();

            // Decide which file this row belongs to.
            let key = if let Some(name) = &spec.partition_by {
                let index = columns_used
                    .iter()
                    .position(|column| &column.name == name)
                    .ok_or_else(|| anyhow!("unknown partition column `{name}`"))?;
                match &values[index] {
                    JsonValue::Null => "null".to_string(),
                    JsonValue::String(text) => text.clone(),
                    other => other.to_string(),
                }
            } else if let Some(rows_per_file) = spec.partition_rows {
                if rows_in_current >= rows_per_file {
                    partition_index += 1;
                    rows_in_current = 0;
                }
                rows_in_current += 1;
                format!("{partition_index}")
            } else {
                String::new()
            };

            if key != current_key || partitions.is_empty() {
                current_key = key.clone();
            }

            if !partitions.contains_key(&key) {
                let path_key = spec.partition_by.as_ref().map(|_| key.as_str());
                let index = if spec.partition_by.is_some() {
                    order.len()
                } else {
                    partition_index
                };
                let target = if spec.preview {
                    Target::Memory {
                        buffer: Vec::new(),
                        rows: 0,
                        partition: (!key.is_empty()).then(|| key.clone()),
                    }
                } else {
                    Target::File(Sink::new(
                        &partition_path(spec, path_key, index),
                        spec,
                        (!key.is_empty()).then(|| key.clone()),
                    )?)
                };
                partitions.insert(
                    key.clone(),
                    Partition {
                        writer: writers::make(spec, &columns_used),
                        target,
                        started: false,
                    },
                );
                order.push(key.clone());
            }

            let partition = partitions.get_mut(&key).expect("partition just inserted");
            if !partition.started {
                partition.started = true;
                let mut buffer = Vec::new();
                partition.writer.begin(&columns_used, &mut buffer)?;
                partition.target.write(&buffer)?;
            }

            let mut buffer = Vec::new();
            partition.writer.row(&columns_used, &values, &mut buffer)?;
            partition.target.write(&buffer)?;
            partition.target.count_row();

            written += 1;
            if written.is_multiple_of(5_000) {
                progress(written);
            }
        }

        Ok(true)
    });

    let total = match total {
        Ok(total) => total,
        Err(error) => {
            sink_error = Some(error);
            written
        }
    };
    let _ = total;

    // An empty result still deserves a header, so create the single file.
    if partitions.is_empty() && !spec.preview && sink_error.is_none() {
        let target = Target::File(Sink::new(&partition_path(spec, None, 0), spec, None)?);
        let mut partition = Partition {
            writer: writers::make(spec, &columns_used),
            target,
            started: true,
        };
        let mut buffer = Vec::new();
        partition.writer.begin(&columns_used, &mut buffer)?;
        partition.target.write(&buffer)?;
        partitions.insert(String::new(), partition);
        order.push(String::new());
    }

    let mut files = Vec::new();
    let mut preview_text: Option<String> = None;

    for key in &order {
        if let Some(mut partition) = partitions.remove(key) {
            let mut buffer = Vec::new();
            partition.writer.finish(&mut buffer)?;
            partition.target.write(&buffer)?;

            match partition.target {
                Target::File(sink) => files.push(sink.finish()?),
                Target::Memory {
                    buffer,
                    rows,
                    partition: name,
                } => {
                    if preview_text.is_none() {
                        preview_text = Some(String::from_utf8_lossy(&buffer).to_string());
                    }
                    files.push(FileReport {
                        path: "<preview>".to_string(),
                        rows,
                        bytes: buffer.len() as u64,
                        sha256: None,
                        partition: name,
                    });
                }
            }
        }
    }

    if let Some(error) = sink_error {
        return Err(error);
    }

    let elapsed = started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64;
    let mut outcome = ExportOutcome {
        rows: written,
        files,
        elapsed_ms: elapsed,
        format: format!("{:?}", spec.format).to_lowercase(),
        manifest: None,
        preview: preview_text,
        warnings,
    };

    if spec.manifest && !spec.preview {
        outcome.manifest = Some(write_manifest(spec, &sql, &columns_used, &outcome)?);
    }

    Ok(outcome)
}

/// Choose and order the columns to export.
fn project(
    columns: &[ColumnDesc],
    requested: Option<&[String]>,
) -> Result<(Vec<usize>, Vec<ColumnDesc>)> {
    let Some(requested) = requested else {
        return Ok(((0..columns.len()).collect(), columns.to_vec()));
    };

    let mut indices = Vec::with_capacity(requested.len());
    let mut chosen = Vec::with_capacity(requested.len());
    for name in requested {
        let index = columns
            .iter()
            .position(|column| &column.name == name)
            .ok_or_else(|| anyhow!("the result has no column `{name}`"))?;
        indices.push(index);
        chosen.push(columns[index].clone());
    }
    Ok((indices, chosen))
}

/// Write the sidecar manifest describing the export.
fn write_manifest(
    spec: &ExportSpec,
    sql: &str,
    columns: &[ColumnDesc],
    outcome: &ExportOutcome,
) -> Result<String> {
    let first = outcome
        .files
        .first()
        .map(|file| file.path.clone())
        .unwrap_or_else(|| shellexpand(&spec.destination));
    let path = PathBuf::from(format!("{first}.manifest.json"));

    let manifest = json!({
        "generated_by": format!("dbclient-core {}", env!("CARGO_PKG_VERSION")),
        "statement": sql,
        "format": outcome.format,
        "rows": outcome.rows,
        "elapsed_ms": outcome.elapsed_ms,
        "columns": columns.iter().map(|column| json!({
            "name": column.name,
            "type": column.type_name,
            "class": column.class.as_str(),
        })).collect::<Vec<_>>(),
        "files": outcome.files,
        // The settings that change how the bytes should be read back.
        "settings": {
            "delimiter": spec.effective_delimiter(),
            "quote": spec.effective_quote().to_string(),
            "quoting": spec.quoting,
            "escape": spec.escape,
            "header": spec.header,
            "line_ending": spec.line_ending,
            "bom": spec.bom,
            "null_as": spec.effective_null(),
            "binary": spec.binary,
            "json_mode": spec.json_mode,
            "decimal_separator": spec.decimal_separator,
            "redacted": spec.redact,
        },
    });

    std::fs::write(&path, serde_json::to_string_pretty(&manifest)?)
        .with_context(|| format!("could not write {}", path.display()))?;
    Ok(path.display().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(format: Format) -> ExportSpec {
        serde_json::from_value(json!({
            "format": format!("{:?}", format).to_lowercase(),
            "destination": "/tmp/out",
            "sql": "select 1",
        }))
        .unwrap()
    }

    #[test]
    fn picks_a_delimiter_for_the_format() {
        assert_eq!(spec(Format::Csv).effective_delimiter(), ",");
        assert_eq!(spec(Format::Tsv).effective_delimiter(), "\t");
    }

    #[test]
    fn moves_the_delimiter_out_of_the_way_of_a_comma_decimal() {
        let mut settings = spec(Format::Csv);
        settings.decimal_separator = Some(",".to_string());
        assert_eq!(
            settings.effective_delimiter(),
            ";",
            "a comma decimal separator collides with a comma delimiter"
        );
    }

    #[test]
    fn builds_sql_from_a_table() {
        let mut settings = spec(Format::Csv);
        settings.sql = None;
        settings.schema = Some("shop".to_string());
        settings.table = Some("customers".to_string());
        settings.filter = Some("city = 'PL'".to_string());
        settings.order = Some("id desc".to_string());

        let sql = settings.build_sql("postgres").unwrap();
        assert_eq!(
            sql,
            "select * from \"shop\".\"customers\" where city = 'PL' order by id desc"
        );
    }

    #[test]
    fn refuses_a_filter_that_smuggles_in_a_statement() {
        let mut settings = spec(Format::Csv);
        settings.sql = None;
        settings.table = Some("t".to_string());
        settings.filter = Some("1=1; drop table t".to_string());
        assert!(settings.build_sql("postgres").is_err());
    }

    #[test]
    fn slugs_a_partition_value() {
        assert_eq!(slug("2026-01-02"), "2026-01-02");
        assert_eq!(slug("ACME Corp / Ltd"), "ACME-Corp---Ltd");
        assert_eq!(slug(""), "null");
        assert_eq!(slug("///"), "null");
    }

    #[test]
    fn names_a_single_file_after_the_destination() {
        let settings = spec(Format::Csv);
        assert_eq!(
            partition_path(&settings, None, 0),
            PathBuf::from("/tmp/out.csv")
        );
    }

    #[test]
    fn keeps_an_extension_the_destination_already_has() {
        let mut settings = spec(Format::Csv);
        settings.destination = "/tmp/report.csv".to_string();
        assert_eq!(
            partition_path(&settings, None, 0),
            PathBuf::from("/tmp/report.csv")
        );
    }

    #[test]
    fn appends_gz_when_compressing() {
        let mut settings = spec(Format::Csv);
        settings.destination = "/tmp/report.csv".to_string();
        settings.compress = Some(Compression::Gzip);
        assert_eq!(
            partition_path(&settings, None, 0),
            PathBuf::from("/tmp/report.csv.gz")
        );
    }

    #[test]
    fn names_partitions_by_value_and_by_index() {
        let mut settings = spec(Format::Csv);
        settings.destination = "/tmp/orders".to_string();

        settings.partition_by = Some("day".to_string());
        assert_eq!(
            partition_path(&settings, Some("2026-01-02"), 0),
            PathBuf::from("/tmp/orders/orders-2026-01-02.csv")
        );

        settings.partition_by = None;
        settings.partition_rows = Some(1000);
        assert_eq!(
            partition_path(&settings, None, 2),
            PathBuf::from("/tmp/orders/orders-0003.csv")
        );
    }

    #[test]
    fn projects_and_reorders_columns() {
        let columns = vec![
            ColumnDesc::text("a"),
            ColumnDesc::text("b"),
            ColumnDesc::text("c"),
        ];
        let requested = vec!["c".to_string(), "a".to_string()];
        let (indices, chosen) = project(&columns, Some(&requested)).unwrap();
        assert_eq!(indices, vec![2, 0]);
        assert_eq!(chosen[0].name, "c");
        assert_eq!(chosen[1].name, "a");
    }

    #[test]
    fn refuses_a_column_the_result_does_not_have() {
        let columns = vec![ColumnDesc::text("a")];
        let requested = vec!["nope".to_string()];
        assert!(project(&columns, Some(&requested)).is_err());
    }
}
