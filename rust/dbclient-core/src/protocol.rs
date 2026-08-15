//! Wire protocol between the Lua front end and the `dbclient-core` daemon.
//!
//! Both directions are newline-delimited JSON. Every request carries an `id`
//! that is echoed on the matching response, so the front end can keep many
//! requests in flight on a single process.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value as JsonValue};
use std::collections::BTreeMap;

/// A single request frame read from stdin.
#[derive(Debug, Deserialize)]
pub struct Request {
    pub id: u64,
    pub op: String,
    #[serde(default)]
    pub session: Option<String>,
    #[serde(default)]
    pub params: JsonValue,
}

/// How a value should be rendered and aligned by the UI.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ValueClass {
    /// Integers, floats, decimals: right aligned.
    Number,
    /// Text-ish values: left aligned.
    Text,
    /// Dates, times, timestamps, intervals.
    Temporal,
    /// Booleans, rendered as check marks.
    Bool,
    /// Binary data, sent to the UI base64 encoded.
    Binary,
    /// JSON / JSONB, pretty printable in the value inspector.
    Json,
    /// Anything the adapter could not classify.
    Unknown,
}

impl ValueClass {
    pub fn as_str(self) -> &'static str {
        match self {
            ValueClass::Number => "number",
            ValueClass::Text => "text",
            ValueClass::Temporal => "temporal",
            ValueClass::Bool => "bool",
            ValueClass::Binary => "binary",
            ValueClass::Json => "json",
            ValueClass::Unknown => "unknown",
        }
    }
}

/// Description of one result column.
#[derive(Clone, Debug, Serialize)]
pub struct ColumnDesc {
    pub name: String,
    /// Database specific type name, shown verbatim in the UI.
    #[serde(rename = "type")]
    pub type_name: String,
    pub class: ValueClass,
}

impl ColumnDesc {
    pub fn new(name: impl Into<String>, type_name: impl Into<String>, class: ValueClass) -> Self {
        Self {
            name: name.into(),
            type_name: type_name.into(),
            class,
        }
    }

    pub fn text(name: impl Into<String>) -> Self {
        Self::new(name, "text", ValueClass::Text)
    }
}

/// A result set plus the statistics the UI shows in the header line.
#[derive(Clone, Debug, Serialize)]
pub struct QueryOutput {
    pub columns: Vec<ColumnDesc>,
    pub rows: Vec<Vec<JsonValue>>,
    pub affected_rows: u64,
    /// True when the adapter stopped fetching because the row cap was hit.
    pub truncated: bool,
    pub elapsed_ms: u64,
    /// Server side notices (PostgreSQL `RAISE NOTICE`, MySQL warnings).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub notices: Vec<String>,
    /// Statement kind as classified by the SQL splitter, e.g. `select`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}

impl QueryOutput {
    pub fn empty() -> Self {
        Self {
            columns: Vec::new(),
            rows: Vec::new(),
            affected_rows: 0,
            truncated: false,
            elapsed_ms: 0,
            notices: Vec::new(),
            kind: None,
        }
    }
}

/// One staged modification produced by the editable data buffer.
#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum RowChange {
    Update {
        schema: String,
        table: String,
        /// Column name to new value.
        set: BTreeMap<String, JsonValue>,
        /// Primary key of the row as it was when the snapshot was taken.
        pk: BTreeMap<String, JsonValue>,
        /// Original values used for optimistic concurrency checks.
        #[serde(default)]
        expect: BTreeMap<String, JsonValue>,
    },
    Insert {
        schema: String,
        table: String,
        values: BTreeMap<String, JsonValue>,
    },
    Delete {
        schema: String,
        table: String,
        pk: BTreeMap<String, JsonValue>,
        #[serde(default)]
        expect: BTreeMap<String, JsonValue>,
    },
}

impl RowChange {
    pub fn schema(&self) -> &str {
        match self {
            RowChange::Update { schema, .. }
            | RowChange::Insert { schema, .. }
            | RowChange::Delete { schema, .. } => schema,
        }
    }

    pub fn table(&self) -> &str {
        match self {
            RowChange::Update { table, .. }
            | RowChange::Insert { table, .. }
            | RowChange::Delete { table, .. } => table,
        }
    }

    pub fn label(&self) -> &'static str {
        match self {
            RowChange::Update { .. } => "update",
            RowChange::Insert { .. } => "insert",
            RowChange::Delete { .. } => "delete",
        }
    }
}

/// Result of applying a batch of [`RowChange`] values.
#[derive(Debug, Serialize)]
pub struct ApplyOutcome {
    pub applied: usize,
    pub affected_rows: u64,
    /// SQL that was executed, in order, for the preview buffer.
    pub statements: Vec<String>,
}

/// Sort direction for previews.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SortDir {
    Asc,
    Desc,
}

impl SortDir {
    pub fn as_sql(self) -> &'static str {
        match self {
            SortDir::Asc => "asc",
            SortDir::Desc => "desc",
        }
    }
}

/// Parameters shared by `preview` and `count`.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct PreviewParams {
    pub schema: String,
    pub table: String,
    #[serde(default)]
    pub limit: Option<u64>,
    #[serde(default)]
    pub offset: Option<u64>,
    /// Raw SQL boolean expression appended as a `where` clause.
    #[serde(default)]
    pub filter: Option<String>,
    /// Column / direction pairs appended as an `order by` clause.
    #[serde(default)]
    pub order: Vec<OrderTerm>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct OrderTerm {
    pub column: String,
    #[serde(default = "default_sort_dir")]
    pub dir: SortDir,
}

fn default_sort_dir() -> SortDir {
    SortDir::Asc
}

pub fn ok_frame(id: u64, data: JsonValue) -> JsonValue {
    json!({ "id": id, "ok": true, "data": data })
}

pub fn err_frame(id: u64, error: &str) -> JsonValue {
    json!({ "id": id, "ok": false, "error": error })
}

pub fn event_frame(event: &str, session: Option<&str>, data: JsonValue) -> JsonValue {
    json!({ "event": event, "session": session, "data": data })
}
