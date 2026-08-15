//! Session abstraction: one live database connection owned by one thread.
//!
//! The old core opened a fresh connection for every command. Sessions keep the
//! connection alive so the front end gets real transactions, session variables,
//! server side cancellation and a stable backend process id.

use crate::protocol::{
    ApplyOutcome, ColumnDesc, PreviewParams, QueryOutput, RowChange, ValueClass,
};
use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;

/// How much a session is allowed to change.
#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Access {
    /// Anything goes.
    #[default]
    Write,
    /// Only statements that return rows are accepted.
    Read,
    /// Writes run inside a transaction that is always rolled back.
    Sandbox,
}

impl Access {
    pub fn as_str(self) -> &'static str {
        match self {
            Access::Write => "write",
            Access::Read => "read",
            Access::Sandbox => "sandbox",
        }
    }
}

/// Everything needed to open one connection.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct ConnectionSpec {
    #[serde(default)]
    pub adapter: String,
    #[serde(default)]
    pub host: Option<String>,
    #[serde(default)]
    pub port: Option<u16>,
    #[serde(default)]
    pub user: Option<String>,
    #[serde(default)]
    pub password: Option<String>,
    #[serde(default)]
    pub database: Option<String>,
    /// SQLite file path.
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub access: Access,
    /// Extra key/value options passed through to the driver where supported.
    #[serde(default)]
    pub options: std::collections::BTreeMap<String, String>,
    /// Statement timeout in milliseconds, applied where the backend supports it.
    #[serde(default)]
    pub statement_timeout_ms: Option<u64>,
}

impl ConnectionSpec {
    pub fn host(&self) -> &str {
        self.host.as_deref().unwrap_or("127.0.0.1")
    }

    pub fn user(&self) -> &str {
        self.user.as_deref().unwrap_or("")
    }

    pub fn require_path(&self) -> Result<&str> {
        self.path
            .as_deref()
            .ok_or_else(|| anyhow!("sqlite connection requires a `path`"))
    }
}

/// A statement the server refused to prepare.
#[derive(Clone, Debug, Serialize)]
pub struct ValidationError {
    pub message: String,
    /// 1-based character position, when the backend reports one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub position: Option<u32>,
}

/// Callback fed each batch of streamed rows; returning `false` stops the scan.
pub type BatchSink<'a> = &'a mut dyn FnMut(&[ColumnDesc], Vec<Vec<JsonValue>>) -> Result<bool>;

/// Static facts about the server behind a session.
#[derive(Clone, Debug, Serialize)]
pub struct BackendInfo {
    pub adapter: String,
    pub server_version: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub database: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backend_pid: Option<i64>,
    pub access: String,
}

/// Cancellation handle usable from a thread other than the session thread.
pub enum CancelHandle {
    Postgres(Box<postgres::CancelToken>),
    /// MySQL needs a second connection to issue `KILL QUERY`.
    MySql {
        opts: Box<mysql::Opts>,
        connection_id: u32,
    },
    Sqlite(rusqlite::InterruptHandle),
    None,
}

impl CancelHandle {
    pub fn cancel(&self) -> Result<()> {
        match self {
            CancelHandle::Postgres(token) => token
                .cancel_query(postgres::NoTls)
                .map_err(|error| anyhow!("failed to cancel PostgreSQL query: {error}")),
            CancelHandle::MySql {
                opts,
                connection_id,
            } => {
                use mysql::prelude::Queryable;
                let mut conn = mysql::Conn::new(opts.as_ref().clone())
                    .map_err(|error| anyhow!("failed to open cancel connection: {error}"))?;
                conn.query_drop(format!("kill query {connection_id}"))
                    .map_err(|error| anyhow!("failed to cancel MySQL query: {error}"))
            }
            CancelHandle::Sqlite(handle) => {
                handle.interrupt();
                Ok(())
            }
            CancelHandle::None => Err(anyhow!("this adapter does not support cancellation")),
        }
    }
}

/// Kind of object whose DDL is requested.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum DdlKind {
    Table,
    View,
    Routine,
    Index,
    Trigger,
}

/// Operations every adapter must provide.
///
/// `&mut self` throughout: a session is owned by exactly one thread, so no
/// interior locking is needed.
pub trait DbSession: Send {
    fn backend_info(&mut self) -> Result<BackendInfo>;

    fn schemas(&mut self) -> Result<Vec<JsonValue>>;
    fn tables(&mut self, schema: &str) -> Result<Vec<JsonValue>>;
    fn columns(&mut self, schema: &str, table: &str) -> Result<Vec<JsonValue>>;
    fn routines(&mut self, schema: &str) -> Result<Vec<JsonValue>>;
    fn indexes(&mut self, schema: &str, table: &str) -> Result<Vec<JsonValue>>;
    fn foreign_keys(&mut self, schema: &str, table: &str) -> Result<Vec<JsonValue>>;
    /// Foreign keys in the whole schema that point *at* `table`.
    fn referencing_keys(&mut self, schema: &str, table: &str) -> Result<Vec<JsonValue>>;

    fn preview(&mut self, params: &PreviewParams) -> Result<QueryOutput>;
    fn count(&mut self, params: &PreviewParams) -> Result<u64>;
    fn query(&mut self, sql: &str, limit: Option<u64>) -> Result<QueryOutput>;

    /// Run a statement and hand its rows to `sink` in batches.
    ///
    /// Export exists to move more rows than fit in memory, so it cannot go
    /// through `query`, which collects everything first. The sink returns
    /// `false` to stop early — that is how cancellation reaches a running
    /// export — and the total number of rows delivered comes back.
    fn stream_query(&mut self, sql: &str, batch_size: usize, sink: BatchSink<'_>) -> Result<u64>;

    /// Ask the server whether a statement is valid, without running it.
    ///
    /// Preparing and discarding is the only way to get the server's own opinion
    /// on names, types and syntax; a client-side linter can only guess. Returns
    /// `None` when the statement is accepted, otherwise the message and, where
    /// the backend reports one, a 1-based character position within `sql`.
    fn validate(&mut self, sql: &str) -> Result<Option<ValidationError>>;
    fn explain(&mut self, sql: &str, analyze: bool) -> Result<JsonValue>;

    fn apply_changes(&mut self, changes: &[RowChange]) -> Result<ApplyOutcome>;
    /// Render the SQL a change set would run, with literals inlined, without
    /// touching the database. Used by the data buffer's confirmation preview.
    fn preview_changes(&mut self, changes: &[RowChange]) -> Result<Vec<String>>;

    fn begin(&mut self) -> Result<()>;
    fn commit(&mut self) -> Result<()>;
    fn rollback(&mut self) -> Result<()>;
    fn in_transaction(&self) -> bool;

    fn ddl(&mut self, kind: DdlKind, schema: &str, name: &str) -> Result<String>;
    fn column_stats(&mut self, schema: &str, table: &str, column: &str) -> Result<JsonValue>;
    fn activity(&mut self) -> Result<QueryOutput>;
    fn locks(&mut self) -> Result<QueryOutput>;
    fn table_sizes(&mut self, schema: &str) -> Result<QueryOutput>;
    fn unused_indexes(&mut self, schema: &str) -> Result<QueryOutput>;

    fn cancel_handle(&mut self) -> CancelHandle {
        CancelHandle::None
    }

    fn access(&self) -> Access;

    /// Which SQL dialect this session speaks, for identifier quoting and for
    /// generated DDL. A value rather than a method on `&self` so callers can
    /// read it before taking the session mutably.
    fn dialect(&self) -> &'static str;

    /// Reject statements the session's access level does not allow.
    fn enforce_access(&self, sql: &str) -> Result<()> {
        if self.access() != Access::Read {
            return Ok(());
        }
        for statement in crate::sqlparse::split(sql) {
            if !statement.returns_rows {
                return Err(anyhow!(
                    "connection is read-only: refusing to run `{}`",
                    statement.kind
                ));
            }
        }
        Ok(())
    }
}

/// Classify a database type name into a rendering class.
///
/// The mapping is deliberately permissive: it matches on substrings so that
/// `character varying(30)`, `varchar(30)` and `VARCHAR` all land on text.
pub fn classify(type_name: &str) -> ValueClass {
    let lower = type_name.to_ascii_lowercase();
    let base = lower.split(['(', ' ']).next().unwrap_or(&lower);

    if matches!(base, "bool" | "boolean" | "bit") && !lower.starts_with("bit varying") {
        return ValueClass::Bool;
    }
    if base.contains("json") {
        return ValueClass::Json;
    }
    if base.contains("blob")
        || base.contains("bytea")
        || base.contains("binary")
        || base == "image"
        || base == "raw"
    {
        return ValueClass::Binary;
    }
    if base.contains("date") || base.contains("time") || base.contains("interval") || base == "year"
    {
        return ValueClass::Temporal;
    }
    if base.contains("int")
        || base.contains("serial")
        || base.contains("dec")
        || base.contains("numeric")
        || base.contains("float")
        || base.contains("double")
        || base.contains("real")
        || base == "money"
        || base == "number"
    {
        return ValueClass::Number;
    }
    if base.contains("char")
        || base.contains("text")
        || base.contains("enum")
        || base.contains("uuid")
        || base.contains("name")
        || base.contains("xml")
        || base.contains("inet")
        || base.contains("cidr")
        || base.contains("macaddr")
    {
        return ValueClass::Text;
    }
    ValueClass::Unknown
}

/// Reject filter expressions that try to smuggle in extra statements.
///
/// The data buffer sends raw SQL boolean expressions typed by the user, which
/// is intentional: filters are a power feature. What we do block is turning a
/// filter into a second statement.
pub fn validate_filter(filter: &str) -> Result<()> {
    let stripped = crate::sqlparse::strip_noise(filter);
    if stripped.contains(';') {
        return Err(anyhow!("filter must be a single boolean expression"));
    }
    if filter.trim().is_empty() {
        return Err(anyhow!("filter is empty"));
    }
    Ok(())
}

/// Cap a requested row limit so a stray `limit 0` or a huge value cannot wedge
/// the UI.
pub fn clamp_limit(limit: Option<u64>, default: u64) -> u64 {
    limit.unwrap_or(default).clamp(1, 200_000)
}

/// Encode binary data for display, matching PostgreSQL's `\x...` hex form so
/// every adapter renders blobs the same way.
pub fn encode_binary(bytes: &[u8]) -> JsonValue {
    let mut out = String::with_capacity(2 + bytes.len() * 2);
    out.push_str("\\x");
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    JsonValue::String(out)
}

/// Base64 for the value inspector, which needs the raw bytes back (image
/// preview, hex dump).
pub fn encode_base64(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// Decode the `\x...` form produced by [`encode_binary`].
pub fn decode_hex(text: &str) -> Option<Vec<u8>> {
    let body = text.strip_prefix("\\x")?;
    if body.len() % 2 != 0 {
        return None;
    }
    (0..body.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&body[index..index + 2], 16).ok())
        .collect()
}

/// Substitute positional placeholders with already quoted literals so a
/// statement can be shown to the user exactly as it will run.
///
/// `marker` is `?` for MySQL and SQLite; PostgreSQL passes `$` and the index is
/// read from the text.
pub fn inline_placeholders(sql: &str, literals: &[String], marker: char) -> String {
    let bytes = sql.as_bytes();
    let mut out = String::with_capacity(sql.len() + 32);
    let mut index = 0usize;
    let mut positional = 0usize;
    let mut in_string = false;

    while index < bytes.len() {
        let byte = bytes[index];
        if in_string {
            out.push(byte as char);
            if byte == b'\'' {
                in_string = false;
            }
            index += 1;
            continue;
        }
        if byte == b'\'' {
            in_string = true;
            out.push('\'');
            index += 1;
            continue;
        }
        if byte == marker as u8 {
            if marker == '$' {
                let start = index + 1;
                let mut cursor = start;
                while cursor < bytes.len() && bytes[cursor].is_ascii_digit() {
                    cursor += 1;
                }
                if cursor > start {
                    let number: usize = sql[start..cursor].parse().unwrap_or(0);
                    let literal = number
                        .checked_sub(1)
                        .and_then(|position| literals.get(position))
                        .cloned()
                        .unwrap_or_else(|| "?".to_string());
                    out.push_str(&literal);
                    index = cursor;
                    continue;
                }
            } else {
                let literal = literals
                    .get(positional)
                    .cloned()
                    .unwrap_or_else(|| "?".to_string());
                out.push_str(&literal);
                positional += 1;
                index += 1;
                continue;
            }
        }
        out.push(byte as char);
        index += 1;
    }

    out
}

/// Milliseconds elapsed since `start`, saturating.
pub fn elapsed_ms(start: std::time::Instant) -> u64 {
    start.elapsed().as_millis().min(u128::from(u64::MAX)) as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_common_types() {
        assert_eq!(classify("int(11)"), ValueClass::Number);
        assert_eq!(classify("bigint"), ValueClass::Number);
        assert_eq!(classify("numeric(10,2)"), ValueClass::Number);
        assert_eq!(classify("character varying(30)"), ValueClass::Text);
        assert_eq!(classify("varchar(30)"), ValueClass::Text);
        assert_eq!(classify("text"), ValueClass::Text);
        assert_eq!(classify("timestamp with time zone"), ValueClass::Temporal);
        assert_eq!(classify("date"), ValueClass::Temporal);
        assert_eq!(classify("boolean"), ValueClass::Bool);
        assert_eq!(classify("tinyint(1)"), ValueClass::Number);
        assert_eq!(classify("jsonb"), ValueClass::Json);
        assert_eq!(classify("bytea"), ValueClass::Binary);
        assert_eq!(classify("longblob"), ValueClass::Binary);
        assert_eq!(classify("uuid"), ValueClass::Text);
    }

    #[test]
    fn rejects_multi_statement_filters() {
        assert!(validate_filter("id = 1").is_ok());
        assert!(validate_filter("name = ';'").is_ok());
        assert!(validate_filter("1=1; drop table users").is_err());
        assert!(validate_filter("   ").is_err());
    }

    #[test]
    fn clamps_limits() {
        assert_eq!(clamp_limit(None, 200), 200);
        assert_eq!(clamp_limit(Some(0), 200), 1);
        assert_eq!(clamp_limit(Some(10_000_000), 200), 200_000);
    }
}
