//! The `serve` daemon.
//!
//! One process hosts many sessions. Each session owns a thread and a live
//! database connection, so a slow query on one connection never blocks the
//! others, and cancellation can reach a running statement from the reader
//! thread while the session thread is still busy.

use crate::adapters::{mariadb::MariaDbSession, postgres::PostgresSession, sqlite::SqliteSession};
use crate::protocol::{err_frame, event_frame, ok_frame, PreviewParams, Request, RowChange};
use crate::session::{CancelHandle, ConnectionSpec, DbSession, DdlKind};
use crate::sqlparse;
use crate::tunnel::{self, SshConfig, TunnelHandle};
use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value as JsonValue};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use std::thread;

pub const PROTOCOL_VERSION: u32 = 1;

type Job = Box<dyn FnOnce(&mut dyn DbSession) + Send>;

enum Message {
    Work(Job),
    Shutdown,
}

struct SessionEntry {
    sender: Sender<Message>,
    cancel: Arc<CancelHandle>,
    join: Option<thread::JoinHandle<()>>,
    adapter: String,
    /// Set while a statement is in flight so `cancel` knows there is a target.
    busy: Arc<AtomicU64>,
}

/// Serialised access to stdout so concurrent sessions cannot interleave frames.
#[derive(Clone)]
pub struct Writer {
    inner: Arc<Mutex<std::io::Stdout>>,
}

impl Writer {
    fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(std::io::stdout())),
        }
    }

    pub fn send(&self, frame: JsonValue) {
        let mut out = match self.inner.lock() {
            Ok(out) => out,
            Err(poisoned) => poisoned.into_inner(),
        };
        if let Ok(text) = serde_json::to_string(&frame) {
            let _ = out.write_all(text.as_bytes());
            let _ = out.write_all(b"\n");
            let _ = out.flush();
        }
    }
}

#[derive(Default)]
struct Registry {
    sessions: HashMap<String, SessionEntry>,
    tunnels: HashMap<String, TunnelHandle>,
    next_id: u64,
}

impl Registry {
    fn next_session_id(&mut self) -> String {
        self.next_id += 1;
        format!("s{}", self.next_id)
    }
}

pub fn serve() -> Result<()> {
    let writer = Writer::new();
    let registry = Arc::new(Mutex::new(Registry::default()));

    writer.send(event_frame(
        "ready",
        None,
        json!({
            "version": env!("CARGO_PKG_VERSION"),
            "protocol": PROTOCOL_VERSION,
        }),
    ));

    let stdin = BufReader::new(std::io::stdin());
    for line in stdin.lines() {
        let line = match line {
            Ok(line) => line,
            Err(_) => break,
        };
        if line.trim().is_empty() {
            continue;
        }

        let request: Request = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(error) => {
                writer.send(err_frame(0, &format!("malformed request: {error}")));
                continue;
            }
        };

        if request.op == "shutdown" {
            writer.send(ok_frame(request.id, json!({ "stopped": true })));
            break;
        }

        dispatch(request, &writer, &registry);
    }

    shutdown_all(&registry);
    Ok(())
}

fn dispatch(request: Request, writer: &Writer, registry: &Arc<Mutex<Registry>>) {
    // Session-scoped work goes to the owning thread; everything else runs on a
    // detached thread so the reader loop never blocks.
    match request.op.as_str() {
        "cancel" => {
            let result = cancel_session(&request, registry);
            reply(writer, request.id, result);
        }
        "close-session" => {
            let result = close_session(&request, registry);
            reply(writer, request.id, result);
        }
        "open-session" => {
            let writer = writer.clone();
            let registry = Arc::clone(registry);
            thread::spawn(move || {
                let result = open_session(&request, &writer, &registry);
                reply(&writer, request.id, result);
            });
        }
        _ if request.session.is_some() => {
            let session_id = request.session.clone().unwrap_or_default();
            let writer = writer.clone();
            let busy = {
                let guard = match registry.lock() {
                    Ok(guard) => guard,
                    Err(poisoned) => poisoned.into_inner(),
                };
                guard
                    .sessions
                    .get(&session_id)
                    .map(|entry| Arc::clone(&entry.busy))
            };

            let sender = {
                let guard = match registry.lock() {
                    Ok(guard) => guard,
                    Err(poisoned) => poisoned.into_inner(),
                };
                guard
                    .sessions
                    .get(&session_id)
                    .map(|entry| entry.sender.clone())
            };

            let Some(sender) = sender else {
                writer.send(err_frame(
                    request.id,
                    &format!("unknown session `{session_id}`"),
                ));
                return;
            };

            let id = request.id;
            let job: Job = Box::new(move |session| {
                if let Some(busy) = &busy {
                    busy.fetch_add(1, Ordering::SeqCst);
                }
                let result = handle_session_op(&request, session);
                if let Some(busy) = &busy {
                    busy.fetch_sub(1, Ordering::SeqCst);
                }
                reply(&writer, id, result);
            });

            if sender.send(Message::Work(job)).is_err() {
                // The receiver is gone; the reply closure went with it.
                let guard = registry.lock();
                drop(guard);
            }
        }
        _ => {
            let writer = writer.clone();
            let registry = Arc::clone(registry);
            thread::spawn(move || {
                let result = handle_global_op(&request, &registry);
                reply(&writer, request.id, result);
            });
        }
    }
}

fn reply(writer: &Writer, id: u64, result: Result<JsonValue>) {
    match result {
        Ok(data) => writer.send(ok_frame(id, data)),
        Err(error) => writer.send(err_frame(id, &format!("{error:#}"))),
    }
}

fn open_session(
    request: &Request,
    writer: &Writer,
    registry: &Arc<Mutex<Registry>>,
) -> Result<JsonValue> {
    let mut spec: ConnectionSpec = serde_json::from_value(
        request
            .params
            .get("connection")
            .cloned()
            .ok_or_else(|| anyhow!("missing `connection`"))?,
    )
    .context("invalid connection spec")?;

    // Optionally open an SSH tunnel first and point the connection at it.
    let mut tunnel_handle: Option<TunnelHandle> = None;
    if let Some(ssh) = request.params.get("ssh") {
        if !ssh.is_null() {
            let mut config: SshConfig =
                serde_json::from_value(ssh.clone()).context("invalid ssh config")?;
            if config.remote_port == 0 {
                config.remote_port = spec.port.unwrap_or(default_port(&spec.adapter));
            }
            let handle = tunnel::open(&config)?;
            spec.host = Some(handle.local_host.clone());
            spec.port = Some(handle.local_port);
            tunnel_handle = Some(handle);
        }
    }

    let adapter = spec.adapter.clone();
    let mut session: Box<dyn DbSession> = match adapter.as_str() {
        "mariadb" | "mysql" => Box::new(MariaDbSession::open(&spec)?),
        "postgres" | "postgresql" | "pg" => Box::new(PostgresSession::open(&spec)?),
        "sqlite" | "sqlite3" => Box::new(SqliteSession::open(&spec)?),
        other => return Err(anyhow!("unknown database adapter: {other}")),
    };

    let info = session.backend_info()?;
    let cancel = Arc::new(session.cancel_handle());
    let busy = Arc::new(AtomicU64::new(0));

    let (sender, receiver) = channel::<Message>();
    let join = thread::Builder::new()
        .name(format!("dbclient-{adapter}"))
        .spawn(move || {
            while let Ok(message) = receiver.recv() {
                match message {
                    Message::Work(job) => job(session.as_mut()),
                    Message::Shutdown => break,
                }
            }
        })
        .context("failed to start session thread")?;

    let session_id = {
        let mut guard = registry.lock().unwrap_or_else(|e| e.into_inner());
        let id = guard.next_session_id();
        guard.sessions.insert(
            id.clone(),
            SessionEntry {
                sender,
                cancel,
                join: Some(join),
                adapter: adapter.clone(),
                busy,
            },
        );
        if let Some(handle) = tunnel_handle {
            guard.tunnels.insert(id.clone(), handle);
        }
        id
    };

    writer.send(event_frame(
        "session-open",
        Some(&session_id),
        json!({ "adapter": adapter }),
    ));

    Ok(json!({
        "session": session_id,
        "info": info,
    }))
}

fn cancel_session(request: &Request, registry: &Arc<Mutex<Registry>>) -> Result<JsonValue> {
    let session_id = request
        .session
        .clone()
        .ok_or_else(|| anyhow!("missing `session`"))?;
    let (cancel, busy) = {
        let guard = registry.lock().unwrap_or_else(|e| e.into_inner());
        let entry = guard
            .sessions
            .get(&session_id)
            .ok_or_else(|| anyhow!("unknown session `{session_id}`"))?;
        (Arc::clone(&entry.cancel), Arc::clone(&entry.busy))
    };

    if busy.load(Ordering::SeqCst) == 0 {
        return Ok(json!({ "cancelled": false, "reason": "no statement in flight" }));
    }
    cancel.cancel()?;
    Ok(json!({ "cancelled": true }))
}

fn close_session(request: &Request, registry: &Arc<Mutex<Registry>>) -> Result<JsonValue> {
    let session_id = request
        .session
        .clone()
        .ok_or_else(|| anyhow!("missing `session`"))?;

    let (entry, tunnel) = {
        let mut guard = registry.lock().unwrap_or_else(|e| e.into_inner());
        (
            guard.sessions.remove(&session_id),
            guard.tunnels.remove(&session_id),
        )
    };

    let Some(mut entry) = entry else {
        return Ok(json!({ "closed": false }));
    };

    let _ = entry.sender.send(Message::Shutdown);
    if let Some(join) = entry.join.take() {
        let _ = join.join();
    }
    if let Some(handle) = tunnel {
        let _ = tunnel::close(&handle);
    }

    Ok(json!({ "closed": true, "adapter": entry.adapter }))
}

fn shutdown_all(registry: &Arc<Mutex<Registry>>) {
    let (sessions, tunnels) = {
        let mut guard = registry.lock().unwrap_or_else(|e| e.into_inner());
        (
            std::mem::take(&mut guard.sessions),
            std::mem::take(&mut guard.tunnels),
        )
    };
    for (_, mut entry) in sessions {
        let _ = entry.sender.send(Message::Shutdown);
        if let Some(join) = entry.join.take() {
            let _ = join.join();
        }
    }
    for (_, handle) in tunnels {
        let _ = tunnel::close(&handle);
    }
}

/// Operations that do not need a database connection.
fn handle_global_op(request: &Request, registry: &Arc<Mutex<Registry>>) -> Result<JsonValue> {
    match request.op.as_str() {
        "version" => Ok(json!({
            "version": env!("CARGO_PKG_VERSION"),
            "protocol": PROTOCOL_VERSION,
        })),
        "split-sql" => {
            let sql = string_param(request, "sql")?;
            Ok(json!({ "statements": sqlparse::split(&sql) }))
        }
        "statement-at" => {
            let sql = string_param(request, "sql")?;
            let offset = request
                .params
                .get("offset")
                .and_then(JsonValue::as_u64)
                .unwrap_or(0) as usize;
            Ok(json!({ "statement": sqlparse::statement_at(&sql, offset) }))
        }
        "lint-sql" => {
            let sql = string_param(request, "sql")?;
            Ok(json!({ "diagnostics": lint(&sql) }))
        }
        "blob" => {
            // The value inspector needs the raw bytes back for hex dumps and
            // terminal image preview.
            let value = string_param(request, "value")?;
            let bytes = crate::session::decode_hex(&value)
                .ok_or_else(|| anyhow!("value is not a `\\x` encoded blob"))?;
            Ok(json!({
                "size": bytes.len(),
                "mime": sniff_mime(&bytes),
                "base64": crate::session::encode_base64(&bytes),
            }))
        }
        "tunnel-status" => {
            let handle: TunnelHandle = serde_json::from_value(
                request
                    .params
                    .get("tunnel")
                    .cloned()
                    .ok_or_else(|| anyhow!("missing `tunnel`"))?,
            )?;
            Ok(json!({ "alive": tunnel::is_alive(&handle) }))
        }
        "tunnel-open" => {
            let config: SshConfig = serde_json::from_value(
                request
                    .params
                    .get("ssh")
                    .cloned()
                    .ok_or_else(|| anyhow!("missing `ssh`"))?,
            )?;
            let handle = tunnel::open(&config)?;
            let key = format!("manual:{}", handle.local_port);
            registry
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .tunnels
                .insert(key, handle.clone());
            Ok(serde_json::to_value(handle)?)
        }
        "tunnel-close" => {
            let handle: TunnelHandle = serde_json::from_value(
                request
                    .params
                    .get("tunnel")
                    .cloned()
                    .ok_or_else(|| anyhow!("missing `tunnel`"))?,
            )?;
            tunnel::close(&handle)?;
            registry
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .tunnels
                .remove(&format!("manual:{}", handle.local_port));
            Ok(json!({ "closed": true }))
        }
        "sessions" => {
            let guard = registry.lock().unwrap_or_else(|e| e.into_inner());
            let list = guard
                .sessions
                .iter()
                .map(|(id, entry)| {
                    json!({
                        "session": id,
                        "adapter": entry.adapter,
                        "busy": entry.busy.load(Ordering::SeqCst) > 0,
                    })
                })
                .collect::<Vec<_>>();
            Ok(json!({ "sessions": list }))
        }
        other => Err(anyhow!("unknown operation `{other}`")),
    }
}

/// Operations that run on the session thread.
fn handle_session_op(request: &Request, session: &mut dyn DbSession) -> Result<JsonValue> {
    let params = &request.params;

    match request.op.as_str() {
        "info" => Ok(serde_json::to_value(session.backend_info()?)?),
        "schemas" => Ok(json!(session.schemas()?)),
        "tables" => Ok(json!(session.tables(&string_param(request, "schema")?)?)),
        "columns" => Ok(json!(session.columns(
            &string_param(request, "schema")?,
            &string_param(request, "table")?
        )?)),
        "routines" => Ok(json!(session.routines(&string_param(request, "schema")?)?)),
        "indexes" => Ok(json!(session.indexes(
            &string_param(request, "schema")?,
            &string_param(request, "table")?
        )?)),
        "foreign-keys" => Ok(json!(session.foreign_keys(
            &string_param(request, "schema")?,
            &string_param(request, "table")?
        )?)),
        "referencing-keys" => Ok(json!(session.referencing_keys(
            &string_param(request, "schema")?,
            &string_param(request, "table")?
        )?)),
        "preview" => {
            let preview: PreviewParams = serde_json::from_value(params.clone())?;
            Ok(serde_json::to_value(session.preview(&preview)?)?)
        }
        "count" => {
            let preview: PreviewParams = serde_json::from_value(params.clone())?;
            Ok(json!({ "count": session.count(&preview)? }))
        }
        "query" => {
            let sql = string_param(request, "sql")?;
            let limit = params.get("limit").and_then(JsonValue::as_u64);
            Ok(serde_json::to_value(session.query(&sql, limit)?)?)
        }
        "execute-script" => {
            let sql = string_param(request, "sql")?;
            let limit = params.get("limit").and_then(JsonValue::as_u64);
            let mut results = Vec::new();
            for statement in sqlparse::split(&sql) {
                let output = session.query(&statement.text, limit)?;
                results.push(json!({
                    "statement": statement,
                    "result": output,
                }));
            }
            Ok(json!({ "results": results }))
        }
        "validate" => {
            // Each statement is prepared on its own, because a script cannot be
            // prepared as a unit and one bad statement should not hide the rest.
            let sql = string_param(request, "sql")?;
            let mut problems = Vec::new();

            for statement in sqlparse::split(&sql) {
                if let Some(error) = session.validate(&statement.text)? {
                    // The backend counts characters within the statement; the
                    // editor needs a byte offset within the whole buffer.
                    let offset = error
                        .position
                        .and_then(|position| {
                            statement
                                .text
                                .char_indices()
                                .nth(position.saturating_sub(1) as usize)
                                .map(|(index, _)| statement.start + index)
                        })
                        .unwrap_or(statement.start);

                    problems.push(json!({
                        "start": offset,
                        "end": statement.end,
                        "severity": "error",
                        "code": "server",
                        "message": error.message,
                    }));
                }
            }

            Ok(json!({ "diagnostics": problems }))
        }
        "blast-radius" => {
            // Show which rows a write would touch, before it touches them.
            let sql = string_param(request, "sql")?;
            let limit = params
                .get("limit")
                .and_then(JsonValue::as_u64)
                .unwrap_or(200);

            let Some((rows_sql, count_sql)) = sqlparse::blast_radius(&sql) else {
                return Ok(json!({
                    "supported": false,
                    "reason": "only UPDATE and DELETE on a single target can be previewed",
                }));
            };

            let preview = session.query(&rows_sql, Some(limit))?;
            let total = session
                .query(&count_sql, Some(1))?
                .rows
                .first()
                .and_then(|row| row.first())
                .and_then(|value| value.as_str())
                .and_then(|value| value.parse::<u64>().ok())
                .unwrap_or(preview.rows.len() as u64);

            Ok(json!({
                "supported": true,
                "kind": sqlparse::leading_keyword(&sql),
                "count": total,
                "sql": rows_sql,
                "result": preview,
            }))
        }
        "explain" => {
            let sql = string_param(request, "sql")?;
            let analyze = params
                .get("analyze")
                .and_then(JsonValue::as_bool)
                .unwrap_or(false);
            session.explain(&sql, analyze)
        }
        "preview-changes" => {
            let changes: Vec<RowChange> = serde_json::from_value(
                params
                    .get("changes")
                    .cloned()
                    .ok_or_else(|| anyhow!("missing `changes`"))?,
            )
            .context("invalid change set")?;
            Ok(json!({ "statements": session.preview_changes(&changes)? }))
        }
        "apply-changes" => {
            let changes: Vec<RowChange> = serde_json::from_value(
                params
                    .get("changes")
                    .cloned()
                    .ok_or_else(|| anyhow!("missing `changes`"))?,
            )
            .context("invalid change set")?;
            Ok(serde_json::to_value(session.apply_changes(&changes)?)?)
        }
        "begin" => {
            session.begin()?;
            Ok(json!({ "in_transaction": true }))
        }
        "commit" => {
            session.commit()?;
            Ok(json!({ "in_transaction": false }))
        }
        "rollback" => {
            session.rollback()?;
            Ok(json!({ "in_transaction": false }))
        }
        "transaction-state" => Ok(json!({ "in_transaction": session.in_transaction() })),
        "ddl" => {
            let kind: DdlKind = serde_json::from_value(
                params
                    .get("kind")
                    .cloned()
                    .unwrap_or_else(|| json!("table")),
            )?;
            let ddl = session.ddl(
                kind,
                &string_param(request, "schema")?,
                &string_param(request, "name")?,
            )?;
            Ok(json!({ "ddl": ddl }))
        }
        "column-stats" => session.column_stats(
            &string_param(request, "schema")?,
            &string_param(request, "table")?,
            &string_param(request, "column")?,
        ),
        "activity" => Ok(serde_json::to_value(session.activity()?)?),
        "locks" => Ok(serde_json::to_value(session.locks()?)?),
        "table-sizes" => Ok(serde_json::to_value(
            session.table_sizes(&string_param(request, "schema")?)?,
        )?),
        "unused-indexes" => Ok(serde_json::to_value(
            session.unused_indexes(&string_param(request, "schema")?)?,
        )?),
        other => Err(anyhow!("unknown session operation `{other}`")),
    }
}

/// Static checks that surface as `vim.diagnostic` entries in the query buffer.
fn lint(sql: &str) -> Vec<JsonValue> {
    let mut diagnostics = Vec::new();
    for statement in sqlparse::split(sql) {
        if sqlparse::is_unfiltered_write(&statement.text) {
            diagnostics.push(json!({
                "start": statement.start,
                "end": statement.end,
                "severity": "error",
                "code": "unfiltered-write",
                "message": format!(
                    "{} without a WHERE clause affects every row",
                    statement.kind.to_uppercase()
                ),
            }));
        }
        if sqlparse::kind_is_write(&statement.kind)
            && matches!(statement.kind.as_str(), "drop" | "truncate")
        {
            diagnostics.push(json!({
                "start": statement.start,
                "end": statement.end,
                "severity": "warn",
                "code": "destructive",
                "message": format!("{} is not reversible", statement.kind.to_uppercase()),
            }));
        }
        if statement.kind == "select"
            && statement.text.contains("*")
            && !sqlparse::contains_keyword(&statement.text, "limit")
            && !sqlparse::contains_keyword(&statement.text, "count")
        {
            diagnostics.push(json!({
                "start": statement.start,
                "end": statement.end,
                "severity": "hint",
                "code": "unbounded-select",
                "message": "SELECT without LIMIT may pull the whole table",
            }));
        }
        if sqlparse::contains_keyword(&statement.text, "join")
            && !sqlparse::contains_keyword(&statement.text, "on")
            && !sqlparse::contains_keyword(&statement.text, "using")
            && !sqlparse::contains_keyword(&statement.text, "natural")
        {
            diagnostics.push(json!({
                "start": statement.start,
                "end": statement.end,
                "severity": "warn",
                "code": "cartesian-join",
                "message": "JOIN without ON or USING produces a cartesian product",
            }));
        }
    }
    diagnostics
}

/// Identify common binary formats from their magic bytes so the value
/// inspector can offer an image preview instead of a hex dump.
fn sniff_mime(bytes: &[u8]) -> &'static str {
    const SIGNATURES: &[(&[u8], &str)] = &[
        (b"\x89PNG\r\n\x1a\n", "image/png"),
        (b"\xff\xd8\xff", "image/jpeg"),
        (b"GIF87a", "image/gif"),
        (b"GIF89a", "image/gif"),
        (b"BM", "image/bmp"),
        (b"%PDF-", "application/pdf"),
        (b"PK\x03\x04", "application/zip"),
        (b"\x1f\x8b", "application/gzip"),
        (b"SQLite format 3\0", "application/vnd.sqlite3"),
    ];

    for (magic, mime) in SIGNATURES {
        if bytes.starts_with(magic) {
            return mime;
        }
    }
    if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return "image/webp";
    }
    if std::str::from_utf8(bytes).is_ok() {
        return "text/plain";
    }
    "application/octet-stream"
}

fn default_port(adapter: &str) -> u16 {
    match adapter {
        "postgres" | "postgresql" | "pg" => 5432,
        _ => 3306,
    }
}

fn string_param(request: &Request, key: &str) -> Result<String> {
    request
        .params
        .get(key)
        .and_then(JsonValue::as_str)
        .map(str::to_string)
        .ok_or_else(|| anyhow!("missing `{key}`"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lints_unfiltered_writes() {
        let diagnostics = lint("delete from users;");
        assert_eq!(diagnostics.len(), 1);
        assert_eq!(diagnostics[0]["code"], "unfiltered-write");
        assert_eq!(diagnostics[0]["severity"], "error");
    }

    #[test]
    fn accepts_filtered_writes() {
        assert!(lint("delete from users where id = 1;").is_empty());
    }

    #[test]
    fn flags_cartesian_joins() {
        let diagnostics = lint("select a.* from a join b");
        assert!(diagnostics.iter().any(|d| d["code"] == "cartesian-join"));
    }

    #[test]
    fn accepts_joins_with_on() {
        let diagnostics = lint("select a.x from a join b on b.id = a.id where a.x = 1");
        assert!(!diagnostics.iter().any(|d| d["code"] == "cartesian-join"));
    }
}
