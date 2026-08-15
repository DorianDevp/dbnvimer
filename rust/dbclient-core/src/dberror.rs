//! Database errors, as structure rather than as prose.
//!
//! Every client in this space hands the driver's error string to the user and
//! stops there. That is why working with a database still feels worse than
//! working with a compiler: `ERROR 1452 (23000): Cannot add or update a child
//! row: a foreign key constraint fails (`shop`.`inquiry`, CONSTRAINT `fk_user`
//! FOREIGN KEY (`user_id`) REFERENCES `user` (`id`))` contains the table, the
//! constraint, the column, the referenced table and the referenced column —
//! everything needed to say "there is no `user` with that `id`" and to put the
//! cursor on `user_id`. All of it is thrown away because nobody parses it.
//!
//! So: parse it. Each backend's errors become the same struct, the front end
//! renders one presentation, and the position — real or recovered — maps back
//! into the buffer the user is looking at.
//!
//! Three sources of position, in order of preference:
//!
//!   1. PostgreSQL reports a character offset directly. It is authoritative.
//!   2. MySQL reports the offending fragment (`near 'FORM users'`) and a line
//!      within the statement. Searching for the fragment recovers the offset,
//!      which is what makes `^` possible on a server that offers no position.
//!   3. SQLite quotes the token (`near "FORM": syntax error`). Same treatment.
//!
//! Everything in this module is a pure function of the message text, so the
//! whole parser is testable without a database — and it is tested against real
//! messages captured from live servers.

use serde::Serialize;
use std::fmt;

/// What went wrong, in terms the front end can act on.
///
/// Deliberately coarse: the point is to decide which explanation to show and
/// what to offer next, not to mirror every SQLSTATE.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    Syntax,
    UndefinedTable,
    UndefinedColumn,
    UndefinedFunction,
    UndefinedDatabase,
    DuplicateObject,
    NotNull,
    ForeignKey,
    Unique,
    Check,
    DataType,
    StringTooLong,
    NumericRange,
    DivisionByZero,
    Collation,
    ColumnCount,
    NoDefault,
    Permission,
    Authentication,
    Deadlock,
    LockTimeout,
    StatementTimeout,
    Cancelled,
    TransactionAborted,
    ReadOnly,
    ConnectionLost,
    TooManyConnections,
    /// Refused by DBClient itself rather than by the server.
    AccessRefused,
    #[default]
    Unknown,
}

impl ErrorKind {
    /// Whether this is the user's statement being wrong, as opposed to the
    /// server, the connection or the data. Only these get a caret.
    pub fn is_statement_fault(self) -> bool {
        matches!(
            self,
            ErrorKind::Syntax
                | ErrorKind::UndefinedTable
                | ErrorKind::UndefinedColumn
                | ErrorKind::UndefinedFunction
                | ErrorKind::DataType
                | ErrorKind::ColumnCount
                | ErrorKind::Collation
        )
    }

    /// Whether retrying the identical statement could plausibly succeed.
    pub fn is_transient(self) -> bool {
        matches!(
            self,
            ErrorKind::Deadlock
                | ErrorKind::LockTimeout
                | ErrorKind::ConnectionLost
                | ErrorKind::TooManyConnections
        )
    }
}

/// One database error, taken apart.
#[derive(Clone, Debug, Default, Serialize)]
pub struct DbError {
    pub kind: ErrorKind,
    /// The server's own words, with driver wrapping removed.
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sqlstate: Option<String>,
    /// Native code: 1064, 23503, SQLITE_CONSTRAINT_NOTNULL.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    /// 1-based character offset into the statement text.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub position: Option<u32>,
    /// The fragment the server quoted, when it quoted one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub near: Option<String>,
    /// 1-based line within the statement, when the server reports one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub constraint: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub schema: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub table: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub column: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub datatype: Option<String>,
    /// The other side of a foreign key.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub referenced_table: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub referenced_column: Option<String>,
    /// The offending value, when the server quoted one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    /// 1-based row of a multi-row insert, when the server counts.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub row: Option<u64>,
    /// Which statement of a multi-statement request failed, 1-based.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub statement_index: Option<u32>,
    /// Byte offset of that statement within the text that was sent.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub statement_offset: Option<u32>,
    /// The statement itself, so the front end can draw a caret without having
    /// to reconstruct what was sent.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub statement: Option<String>,
    pub adapter: String,

    /// A 0-based *byte* offset, which is what SQLite reports. Converted to a
    /// character position once the statement is known, then dropped: shipping
    /// two kinds of offset would guarantee that one of them gets used wrongly.
    #[serde(skip)]
    pub byte_offset: Option<u32>,
}

impl fmt::Display for DbError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.message)
    }
}

impl std::error::Error for DbError {}

impl DbError {
    pub fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
            ..Default::default()
        }
    }

    /// Attach the statement this error came from, and recover a position from
    /// the quoted fragment when the server did not give one.
    pub fn with_statement(mut self, sql: &str, index: Option<u32>, offset: Option<u32>) -> Self {
        self.statement = Some(sql.to_string());
        self.statement_index = index;
        self.statement_offset = offset;

        if self.position.is_none() {
            if let Some(byte) = self.byte_offset {
                // Characters, not bytes: a caret placed by byte offset drifts
                // once anything before it leaves ASCII.
                if let Some(prefix) = sql.get(..byte as usize) {
                    self.position = Some(prefix.chars().count() as u32 + 1);
                }
            }
        }
        if self.position.is_none() {
            self.position = recover_position(sql, self.near.as_deref(), self.line);
        }
        self
    }

    pub fn with_adapter(mut self, adapter: &str) -> Self {
        self.adapter = adapter.to_string();
        self
    }
}

/// Find where a quoted fragment sits in the statement.
///
/// MySQL and SQLite name the offending text but not its offset, so the offset
/// has to be found. When a line is also given the search starts there, which
/// disambiguates a fragment that occurs more than once — `near 'from'` in a
/// statement with two subqueries would otherwise always point at the first.
pub fn recover_position(sql: &str, near: Option<&str>, line: Option<u32>) -> Option<u32> {
    let near = near?.trim();
    if near.is_empty() {
        return None;
    }

    // Where to start looking: the beginning of the reported line.
    let start_byte = match line {
        Some(line) if line > 1 => {
            let mut remaining = line - 1;
            let mut byte = 0usize;
            for (index, character) in sql.char_indices() {
                if character == '\n' {
                    remaining -= 1;
                    if remaining == 0 {
                        byte = index + 1;
                        break;
                    }
                }
            }
            byte
        }
        _ => 0,
    };

    // The server truncates the fragment, so an exact match can fail on a long
    // one. Shorten from the right until something matches — the first token is
    // what matters and it is the part that is never cut.
    let mut candidate = near;
    loop {
        if let Some(found) = sql
            .get(start_byte..)
            .and_then(|tail| tail.find(candidate))
            .map(|found| found + start_byte)
        {
            // Character offset, not byte offset: the front end counts
            // characters and so does PostgreSQL.
            return Some(sql[..found].chars().count() as u32 + 1);
        }
        match candidate.rfind(char::is_whitespace) {
            Some(cut) if cut > 0 => candidate = candidate[..cut].trim_end(),
            _ => return None,
        }
    }
}

// ---------------------------------------------------------------------------
// PostgreSQL
// ---------------------------------------------------------------------------

/// Map a SQLSTATE to a kind.
///
/// PostgreSQL is the only one of the three that reports SQLSTATE reliably, and
/// it is the best signal available: the codes are stable across versions and
/// documented, unlike the message text.
pub fn kind_from_sqlstate(state: &str) -> ErrorKind {
    match state {
        "42601" => ErrorKind::Syntax,
        "42P01" | "42P02" => ErrorKind::UndefinedTable,
        "42703" => ErrorKind::UndefinedColumn,
        "42883" => ErrorKind::UndefinedFunction,
        "3D000" => ErrorKind::UndefinedDatabase,
        "42P07" | "42710" => ErrorKind::DuplicateObject,
        "23502" => ErrorKind::NotNull,
        "23503" => ErrorKind::ForeignKey,
        "23505" => ErrorKind::Unique,
        "23514" | "23P01" => ErrorKind::Check,
        "22001" => ErrorKind::StringTooLong,
        "22003" => ErrorKind::NumericRange,
        "22012" => ErrorKind::DivisionByZero,
        "22007" | "22008" | "22P02" | "42804" | "42883 " => ErrorKind::DataType,
        "42501" => ErrorKind::Permission,
        "28P01" | "28000" => ErrorKind::Authentication,
        "40P01" => ErrorKind::Deadlock,
        "55P03" => ErrorKind::LockTimeout,
        "57014" => ErrorKind::Cancelled,
        "25P02" => ErrorKind::TransactionAborted,
        "25006" => ErrorKind::ReadOnly,
        "53300" => ErrorKind::TooManyConnections,
        "08000" | "08003" | "08006" | "08001" | "08004" | "57P01" | "57P02" | "57P03" => {
            ErrorKind::ConnectionLost
        }
        other if other.starts_with("42") => ErrorKind::Syntax,
        other if other.starts_with("23") => ErrorKind::Check,
        other if other.starts_with("22") => ErrorKind::DataType,
        other if other.starts_with("08") => ErrorKind::ConnectionLost,
        _ => ErrorKind::Unknown,
    }
}

pub fn from_postgres(error: &postgres::Error) -> DbError {
    let Some(db) = error.as_db_error() else {
        let message = error.to_string();
        let kind = if message.contains("timed out") || message.contains("connection closed") {
            ErrorKind::ConnectionLost
        } else {
            ErrorKind::Unknown
        };
        return DbError::new(kind, message).with_adapter("postgres");
    };

    let state = db.code().code().to_string();
    let position = match db.position() {
        Some(postgres::error::ErrorPosition::Original(position)) => Some(*position),
        Some(postgres::error::ErrorPosition::Internal { position, .. }) => Some(*position),
        None => None,
    };

    DbError {
        kind: kind_from_sqlstate(&state),
        message: db.message().to_string(),
        sqlstate: Some(state.clone()),
        code: Some(state),
        position,
        detail: db.detail().map(str::to_string),
        hint: db.hint().map(str::to_string),
        constraint: db.constraint().map(str::to_string),
        schema: db.schema().map(str::to_string),
        table: db.table().map(str::to_string),
        column: db.column().map(str::to_string),
        datatype: db.datatype().map(str::to_string),
        adapter: "postgres".into(),
        ..Default::default()
    }
    // PostgreSQL puts the offending key in DETAIL rather than in the fields:
    // `Key (user_id)=(9999) is not present in table "user".`
    .enrich_from_detail()
    .enrich_from_message()
}

impl DbError {
    /// PostgreSQL's DETAIL line carries the parts the structured fields omit.
    ///
    /// `Key (user_id)=(9999) is not present in table "user".` names the column,
    /// the value and the referenced table — all three of which the front end
    /// needs to say something useful and none of which arrive as fields.
    pub fn enrich_from_detail(mut self) -> Self {
        let Some(detail) = self.detail.clone() else {
            return self;
        };

        if let Some((column, value)) = parse_key_detail(&detail) {
            if self.column.is_none() {
                self.column = Some(column);
            }
            if self.value.is_none() {
                self.value = Some(value);
            }
        }

        if let Some(referenced) = detail
            .split("is not present in table \"")
            .nth(1)
            .and_then(|tail| tail.split('"').next())
        {
            self.referenced_table = Some(referenced.to_string());
        }
        if let Some(referenced) = detail
            .split("still referenced from table \"")
            .nth(1)
            .and_then(|tail| tail.split('"').next())
        {
            self.referenced_table = Some(referenced.to_string());
        }

        self
    }
}

impl DbError {
    /// Pull the identifier out of a "does not exist" message.
    ///
    /// PostgreSQL populates `column` and `table` for constraint violations and
    /// not for `column "priorty" does not exist`, where the name appears only
    /// inside the message. Without it there is nothing to compare against the
    /// schema, so the one case where "did you mean" is most wanted is the one
    /// case it would never fire.
    pub fn enrich_from_message(mut self) -> Self {
        let quoted = self
            .message
            .split('"')
            .nth(1)
            .filter(|name| !name.is_empty() && !name.contains(' '));

        match self.kind {
            ErrorKind::UndefinedColumn => {
                if self.column.is_none() {
                    self.column = quoted.map(str::to_string);
                }
                if self.near.is_none() {
                    self.near = self.column.clone();
                }
            }
            ErrorKind::UndefinedTable => {
                if self.table.is_none() {
                    self.table = quoted.map(str::to_string);
                }
                if self.near.is_none() {
                    self.near = self.table.clone();
                }
            }
            // `function no_such_fn(integer) does not exist` — unquoted, and the
            // signature is not part of the name.
            ErrorKind::UndefinedFunction if self.near.is_none() => {
                self.near = self
                    .message
                    .strip_prefix("function ")
                    .and_then(|tail| tail.split('(').next())
                    .map(str::to_string);
            }
            _ => {}
        }
        self
    }
}

/// `Key (user_id)=(9999) is not present in table "user".`
fn parse_key_detail(detail: &str) -> Option<(String, String)> {
    let rest = detail.strip_prefix("Key (")?;
    let (column, rest) = rest.split_once(")=(")?;
    let (value, _) = rest.split_once(')')?;
    Some((column.to_string(), value.to_string()))
}

// ---------------------------------------------------------------------------
// MySQL and MariaDB
// ---------------------------------------------------------------------------

/// Take a MySQL error apart.
///
/// MySQL reports no position and its SQLSTATE is coarse, so almost everything
/// useful is in the message — which is, fortunately, generated from format
/// strings that have barely changed in twenty years. Parsing it is the only way
/// to get the constraint, the column and the offending value, and those are
/// exactly what turns "constraint fails" into a sentence worth reading.
pub fn parse_mysql(code: u16, sqlstate: &str, message: &str) -> DbError {
    let mut error = DbError {
        code: Some(code.to_string()),
        sqlstate: (!sqlstate.is_empty()).then(|| sqlstate.to_string()),
        message: message.to_string(),
        adapter: "mariadb".into(),
        ..Default::default()
    };

    match code {
        1064 | 1149 => {
            error.kind = ErrorKind::Syntax;
            // `... near 'FORM users' at line 1`
            if let Some(tail) = message.split("near '").nth(1) {
                if let Some((fragment, rest)) = tail.rsplit_once('\'') {
                    error.near = Some(fragment.to_string());
                    error.line = rest
                        .split("at line ")
                        .nth(1)
                        .and_then(|number| number.trim().parse().ok());
                }
            }
            // The manual reference is noise in a UI that is about to explain
            // the error itself.
            error.message = "syntax error".to_string();
        }
        1054 => {
            error.kind = ErrorKind::UndefinedColumn;
            // `Unknown column 'statuz' in 'where clause'`
            error.column = quoted(message, '\'');
            error.near = error.column.clone();
            if let Some(column) = &error.column {
                error.message = format!("there is no column `{column}`");
            }
        }
        1146 => {
            error.kind = ErrorKind::UndefinedTable;
            // `Table 'shop.userz' doesn't exist`
            if let Some(qualified) = quoted(message, '\'') {
                let (schema, table) = split_qualified(&qualified);
                error.schema = schema;
                error.table = Some(table.clone());
                error.near = Some(table.clone());
                error.message = format!("there is no table `{table}`");
            }
        }
        1049 => {
            error.kind = ErrorKind::UndefinedDatabase;
            error.schema = quoted(message, '\'');
        }
        1305 | 1630 => {
            error.kind = ErrorKind::UndefinedFunction;
            // `FUNCTION shop.foo does not exist`
            if let Some(name) = message.split_whitespace().nth(1) {
                let (_, function) = split_qualified(name);
                error.near = Some(function.clone());
                error.message = format!("there is no function `{function}`");
            }
        }
        1050 | 1061 | 1060 | 1022 => {
            error.kind = ErrorKind::DuplicateObject;
        }
        1451 | 1452 => {
            error.kind = ErrorKind::ForeignKey;
            parse_mysql_foreign_key(message, &mut error);
            error.message = if code == 1452 {
                "a referenced row does not exist".to_string()
            } else {
                "other rows still reference this one".to_string()
            };
        }
        1062 | 1586 => {
            error.kind = ErrorKind::Unique;
            // `Duplicate entry 'jan@ventia.pl' for key 'user.email_unique'`
            error.value = quoted(message, '\'');
            if let Some(key) = message
                .split("for key '")
                .nth(1)
                .and_then(|t| t.split('\'').next())
            {
                let (table, name) = split_qualified(key);
                error.constraint = Some(name);
                if error.table.is_none() {
                    error.table = table;
                }
            }
            error.message = "that value is already taken".to_string();
        }
        1048 => {
            error.kind = ErrorKind::NotNull;
            // `Column 'name' cannot be null`
            error.column = quoted(message, '\'');
            if let Some(column) = &error.column {
                error.message = format!("`{column}` cannot be null");
            }
        }
        1364 => {
            error.kind = ErrorKind::NoDefault;
            error.column = quoted(message, '\'');
            if let Some(column) = &error.column {
                error.message = format!("`{column}` has no default and was not given a value");
            }
        }
        1406 | 1265 => {
            error.kind = if code == 1406 {
                ErrorKind::StringTooLong
            } else {
                ErrorKind::DataType
            };
            error.column = for_column(message);
            error.row = at_row(message);
            if let Some(column) = &error.column {
                error.message = if code == 1406 {
                    format!("the value is too long for `{column}`")
                } else {
                    format!("the value does not fit `{column}` and would be truncated")
                };
            }
        }
        1264 => {
            error.kind = ErrorKind::NumericRange;
            error.column = for_column(message);
            error.row = at_row(message);
            if let Some(column) = &error.column {
                error.message = format!("the value is outside the range of `{column}`");
            }
        }
        1292 | 1366 | 1525 => {
            error.kind = ErrorKind::DataType;
            error.column = for_column(message);
            error.row = at_row(message);
            // `Incorrect datetime value: '2026-02-30' for column ...`
            error.value = message
                .split(": '")
                .nth(1)
                .and_then(|tail| tail.split('\'').next())
                .map(str::to_string);
            if let Some(column) = &error.column {
                error.message = format!("the value is not valid for `{column}`");
            }
        }
        3819 | 4025 => {
            error.kind = ErrorKind::Check;
            // 8.0: `Check constraint 'chk_priority' is violated.`
            // MariaDB: `CONSTRAINT `chk` failed for `db`.`t``
            error.constraint = quoted(message, '\'').or_else(|| quoted(message, '`'));
            error.message = match &error.constraint {
                Some(name) => format!("the check constraint `{name}` rejected this"),
                None => "a check constraint rejected this".to_string(),
            };
        }
        1136 => {
            error.kind = ErrorKind::ColumnCount;
            error.row = at_row(message);
            error.message = "the number of values does not match the number of columns".into();
        }
        1267 | 1270 => {
            error.kind = ErrorKind::Collation;
            error.message = "two columns in this comparison use different collations".into();
        }
        1044 | 1142 | 1143 | 1227 | 1370 => {
            error.kind = ErrorKind::Permission;
        }
        1045 | 1698 => {
            error.kind = ErrorKind::Authentication;
        }
        1213 => error.kind = ErrorKind::Deadlock,
        1205 => error.kind = ErrorKind::LockTimeout,
        3024 => error.kind = ErrorKind::StatementTimeout,
        1317 => error.kind = ErrorKind::Cancelled,
        1290 | 1836 => error.kind = ErrorKind::ReadOnly,
        1040 | 1203 => error.kind = ErrorKind::TooManyConnections,
        2002 | 2003 | 2006 | 2013 | 4031 => error.kind = ErrorKind::ConnectionLost,
        _ => {
            error.kind = if sqlstate.is_empty() {
                ErrorKind::Unknown
            } else {
                kind_from_sqlstate(sqlstate)
            };
        }
    }

    error
}

/// ``(`shop`.`inquiry`, CONSTRAINT `fk_user` FOREIGN KEY (`user_id`) REFERENCES `user` (`id`))``
fn parse_mysql_foreign_key(message: &str, error: &mut DbError) {
    let mut parts = message.split("CONSTRAINT `");
    if let Some(head) = parts.next() {
        // The qualified table sits between the last `(` and the first comma.
        if let Some(inner) = head.rsplit('(').next() {
            let names = backticked(inner);
            match names.len() {
                2 => {
                    error.schema = Some(names[0].clone());
                    error.table = Some(names[1].clone());
                }
                1 => error.table = Some(names[0].clone()),
                _ => {}
            }
        }
    }

    let Some(tail) = parts.next() else { return };
    if let Some((name, rest)) = tail.split_once('`') {
        error.constraint = Some(name.to_string());

        if let Some(columns) = rest.split("FOREIGN KEY (").nth(1) {
            error.column = backticked(columns).first().cloned();
        }
        if let Some(references) = rest.split("REFERENCES ").nth(1) {
            let names = backticked(references);
            if let Some(table) = names.first() {
                error.referenced_table = Some(table.clone());
            }
            if let Some(column) = names.get(1) {
                error.referenced_column = Some(column.clone());
            }
        }
    }
}

/// Every `` `identifier` `` in order.
fn backticked(text: &str) -> Vec<String> {
    let mut names = Vec::new();
    let mut rest = text;
    while let Some(start) = rest.find('`') {
        rest = &rest[start + 1..];
        match rest.find('`') {
            Some(end) => {
                names.push(rest[..end].to_string());
                rest = &rest[end + 1..];
            }
            None => break,
        }
    }
    names
}

/// The first `'quoted'` or `` `quoted` `` run.
fn quoted(text: &str, delimiter: char) -> Option<String> {
    let start = text.find(delimiter)? + delimiter.len_utf8();
    let rest = &text[start..];
    let end = rest.find(delimiter)?;
    Some(rest[..end].to_string())
}

/// The column named by `for column ...`, which several messages share.
///
/// Two shapes, depending on the server and the statement: `for column 'label'`
/// and `for column 'shop'.'child'.'priority'`. Taking the first quoted run gets
/// the schema in the second case and reports the database as the offending
/// column, so the *last* run is the one that matters.
fn for_column(message: &str) -> Option<String> {
    let tail = message.split("for column ").nth(1)?;
    let tail = tail.split(" at row ").next().unwrap_or(tail);

    let mut last = None;
    for delimiter in ['\'', '`'] {
        let mut rest = tail;
        while let Some(start) = rest.find(delimiter) {
            rest = &rest[start + delimiter.len_utf8()..];
            match rest.find(delimiter) {
                Some(end) => {
                    last = Some(rest[..end].to_string());
                    rest = &rest[end + delimiter.len_utf8()..];
                }
                None => break,
            }
        }
        if last.is_some() {
            break;
        }
    }
    last
}

/// `at row 4`
fn at_row(message: &str) -> Option<u64> {
    message
        .split("at row ")
        .nth(1)
        .and_then(|tail| {
            tail.split(|character: char| !character.is_ascii_digit())
                .next()
        })
        .and_then(|digits| digits.parse().ok())
}

/// `shop.inquiry` or `` `shop`.`inquiry` `` into its parts.
fn split_qualified(name: &str) -> (Option<String>, String) {
    let cleaned = name.replace(['`', '"'], "");
    match cleaned.rsplit_once('.') {
        Some((schema, object)) => (Some(schema.to_string()), object.to_string()),
        None => (None, cleaned),
    }
}

pub fn from_mysql(error: &mysql::Error) -> DbError {
    match error {
        mysql::Error::MySqlError(server) => {
            parse_mysql(server.code, &server.state, &server.message)
        }
        mysql::Error::IoError(io) => {
            DbError::new(ErrorKind::ConnectionLost, io.to_string()).with_adapter("mariadb")
        }
        mysql::Error::DriverError(driver) => {
            let message = driver.to_string();
            let kind = if message.contains("connection") || message.contains("Lost") {
                ErrorKind::ConnectionLost
            } else {
                ErrorKind::Unknown
            };
            DbError::new(kind, message).with_adapter("mariadb")
        }
        other => DbError::new(ErrorKind::Unknown, other.to_string()).with_adapter("mariadb"),
    }
}

// ---------------------------------------------------------------------------
// SQLite
// ---------------------------------------------------------------------------

/// Strip the `in <sql> at offset N` tail rusqlite appends, keeping the offset.
///
/// That offset is a 0-based *byte* index into the statement and is the only
/// position SQLite offers, so it is worth the parsing. The tail itself is noise:
/// it repeats the statement the user is already looking at.
fn split_sqlite_offset(message: &str) -> (String, Option<u32>) {
    let Some(cut) = message.rfind(" at offset ") else {
        return (message.to_string(), None);
    };
    let offset: Option<u32> = message[cut + " at offset ".len()..].trim().parse().ok();
    if offset.is_none() {
        return (message.to_string(), None);
    }

    let head = &message[..cut];
    // What remains is `<real message> in <the statement>`; drop the echo.
    let head = match head.rfind(" in ") {
        Some(inner) => &head[..inner],
        None => head,
    };
    (head.to_string(), offset)
}

/// SQLite's messages are terse but regular.
///
/// Matched case-insensitively but extracted from the original text: the names
/// SQLite quotes are the user's identifiers, and lowercasing them would break
/// both the caret search and the "did you mean" comparison on any schema that
/// uses capitals.
pub fn parse_sqlite(extended_code: i32, raw: &str) -> DbError {
    let (message, byte_offset) = split_sqlite_offset(raw);
    let mut error = DbError {
        message: message.clone(),
        // rusqlite reports 0 when it has no extended code to give. Showing it
        // as a code is noise dressed up as information.
        code: (extended_code != 0).then(|| extended_code.to_string()),
        byte_offset,
        adapter: "sqlite".into(),
        ..Default::default()
    };

    let lowered = message.to_ascii_lowercase();

    /// The remainder of `message` after a known lowercase prefix, with the
    /// original casing intact.
    fn after<'a>(message: &'a str, lowered: &str, prefix: &str) -> Option<&'a str> {
        lowered
            .starts_with(prefix)
            .then(|| message[prefix.len()..].trim())
    }

    if after(&message, &lowered, "near \"").is_some() {
        error.kind = ErrorKind::Syntax;
        error.near = message["near \"".len()..]
            .split('"')
            .next()
            .map(str::to_string);
        error.message = "syntax error".into();
        return error;
    }

    if let Some(target) = after(&message, &lowered, "not null constraint failed: ") {
        error.kind = ErrorKind::NotNull;
        let (table, column) = split_qualified(target);
        error.table = table;
        error.column = Some(column.clone());
        error.message = format!("`{column}` cannot be null");
        return error;
    }

    if let Some(target) = after(&message, &lowered, "unique constraint failed: ") {
        error.kind = ErrorKind::Unique;
        // A composite key lists several columns; the table is the same for all.
        let first = target.split(", ").next().unwrap_or(target);
        let (table, column) = split_qualified(first);
        error.table = table;
        error.column = Some(column);
        error.message = "that value is already taken".into();
        return error;
    }

    if lowered.starts_with("foreign key constraint failed") {
        error.kind = ErrorKind::ForeignKey;
        error.message = "a referenced row does not exist".into();
        return error;
    }

    if let Some(name) = after(&message, &lowered, "check constraint failed: ") {
        error.kind = ErrorKind::Check;
        error.constraint = Some(name.to_string());
        error.message = format!("the check constraint `{name}` rejected this");
        return error;
    }

    if let Some(name) = after(&message, &lowered, "no such column: ") {
        error.kind = ErrorKind::UndefinedColumn;
        error.column = Some(name.to_string());
        error.near = Some(name.to_string());
        error.message = format!("there is no column `{name}`");
        return error;
    }

    if let Some(name) = after(&message, &lowered, "no such table: ") {
        error.kind = ErrorKind::UndefinedTable;
        let (schema, table) = split_qualified(name);
        error.schema = schema;
        error.near = Some(table.clone());
        error.table = Some(table.clone());
        error.message = format!("there is no table `{table}`");
        return error;
    }

    if let Some(name) = after(&message, &lowered, "no such function: ") {
        error.kind = ErrorKind::UndefinedFunction;
        error.near = Some(name.to_string());
        error.message = format!("there is no function `{name}`");
        return error;
    }

    error.kind = match () {
        _ if lowered.contains("datatype mismatch") => ErrorKind::DataType,
        _ if lowered.contains("database is locked") => ErrorKind::LockTimeout,
        _ if lowered.contains("interrupted") => ErrorKind::Cancelled,
        _ if lowered.contains("readonly") || lowered.contains("read-only") => ErrorKind::ReadOnly,
        _ if lowered.contains("attempt to write") => ErrorKind::ReadOnly,
        _ if lowered.contains("syntax error") => ErrorKind::Syntax,
        _ if lowered.contains("already exists") => ErrorKind::DuplicateObject,
        _ => ErrorKind::Unknown,
    };
    error
}

pub fn from_sqlite(error: &rusqlite::Error) -> DbError {
    match error {
        rusqlite::Error::SqliteFailure(code, Some(message)) => {
            parse_sqlite(code.extended_code, message)
        }
        rusqlite::Error::SqliteFailure(code, None) => {
            DbError::new(ErrorKind::Unknown, code.to_string()).with_adapter("sqlite")
        }
        other => {
            let message = other.to_string();
            parse_sqlite(0, &message)
        }
    }
}

// ---------------------------------------------------------------------------
// Errors that are ours rather than the server's
// ---------------------------------------------------------------------------

/// Classify an error DBClient raised itself.
///
/// A refused write, a missing parameter, a tunnel that would not open: none of
/// these come from a driver, but the front end should still get one shape to
/// render rather than falling back to bare prose for half the failures it sees.
pub fn classify_local(message: &str) -> DbError {
    let lowered = message.to_ascii_lowercase();

    let kind = if lowered.contains("connection is read-only") || lowered.contains("refusing to run")
    {
        ErrorKind::AccessRefused
    } else if lowered.contains("cancelled") || lowered.contains("canceled") {
        ErrorKind::Cancelled
    } else if lowered.contains("timed out") || lowered.contains("timeout") {
        ErrorKind::StatementTimeout
    } else if lowered.contains("failed to connect")
        || lowered.contains("connection refused")
        || lowered.contains("no route to host")
        || lowered.contains("broken pipe")
    {
        ErrorKind::ConnectionLost
    } else if lowered.contains("unknown table") {
        ErrorKind::UndefinedTable
    } else if lowered.contains("unknown column") {
        ErrorKind::UndefinedColumn
    } else {
        ErrorKind::Unknown
    };

    DbError::new(kind, message)
}

/// Attach a statement's identity to whatever error came out of running it.
///
/// The error may already be a typed `DbError` deep in an `anyhow` chain, in
/// which case the statement is threaded into that copy; otherwise the message
/// is classified and located as best it can be. Either way the caller gets back
/// an `anyhow::Error` that still prints the same.
pub fn locate(error: anyhow::Error, sql: &str, index: u32, offset: u32) -> anyhow::Error {
    for cause in error.chain() {
        if let Some(db) = cause.downcast_ref::<DbError>() {
            let context = format!("{error:#}");
            let located = db.clone().with_statement(sql, Some(index), Some(offset));
            // Keep the surrounding context: it says what was being attempted.
            return if context == db.message {
                anyhow::Error::new(located)
            } else {
                anyhow::Error::new(located).context(context)
            };
        }
    }

    let message = format!("{error:#}");
    anyhow::Error::new(classify_local(&message).with_statement(sql, Some(index), Some(offset)))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Every message below was captured from a live server rather than written
    // from memory, because these format strings are the whole contract and
    // guessing at them is how a parser silently stops matching.

    #[test]
    fn mysql_syntax_error_names_the_fragment_and_the_line() {
        let error = parse_mysql(
            1064,
            "42000",
            "You have an error in your SQL syntax; check the manual that corresponds to your \
             MariaDB server version for the right syntax to use near 'FORM users' at line 1",
        );
        assert_eq!(error.kind, ErrorKind::Syntax);
        assert_eq!(error.near.as_deref(), Some("FORM users"));
        assert_eq!(error.line, Some(1));
        // The manual reference is not information.
        assert_eq!(error.message, "syntax error");
    }

    #[test]
    fn mysql_syntax_error_on_a_later_line() {
        let error = parse_mysql(
            1064,
            "42000",
            "You have an error in your SQL syntax; ... near 'wibble' at line 3",
        );
        assert_eq!(error.line, Some(3));
        assert_eq!(error.near.as_deref(), Some("wibble"));
    }

    #[test]
    fn mysql_unknown_column() {
        let error = parse_mysql(1054, "42S22", "Unknown column 'statuz' in 'where clause'");
        assert_eq!(error.kind, ErrorKind::UndefinedColumn);
        assert_eq!(error.column.as_deref(), Some("statuz"));
        assert_eq!(error.near.as_deref(), Some("statuz"));
    }

    #[test]
    fn mysql_unknown_table_splits_the_schema_off() {
        let error = parse_mysql(1146, "42S02", "Table 'shop.userz' doesn't exist");
        assert_eq!(error.kind, ErrorKind::UndefinedTable);
        assert_eq!(error.schema.as_deref(), Some("shop"));
        assert_eq!(error.table.as_deref(), Some("userz"));
        // The caret goes on the table, not on the schema that was correct.
        assert_eq!(error.near.as_deref(), Some("userz"));
    }

    #[test]
    fn mysql_foreign_key_yields_both_sides() {
        let error = parse_mysql(
            1452,
            "23000",
            "Cannot add or update a child row: a foreign key constraint fails \
             (`shop`.`inquiry`, CONSTRAINT `fk_inquiry_user` FOREIGN KEY (`user_id`) \
             REFERENCES `user` (`id`))",
        );
        assert_eq!(error.kind, ErrorKind::ForeignKey);
        assert_eq!(error.schema.as_deref(), Some("shop"));
        assert_eq!(error.table.as_deref(), Some("inquiry"));
        assert_eq!(error.constraint.as_deref(), Some("fk_inquiry_user"));
        assert_eq!(error.column.as_deref(), Some("user_id"));
        assert_eq!(error.referenced_table.as_deref(), Some("user"));
        assert_eq!(error.referenced_column.as_deref(), Some("id"));
    }

    #[test]
    fn mysql_foreign_key_the_other_way_round() {
        let error = parse_mysql(
            1451,
            "23000",
            "Cannot delete or update a parent row: a foreign key constraint fails \
             (`shop`.`inquiry`, CONSTRAINT `fk_inquiry_user` FOREIGN KEY (`user_id`) \
             REFERENCES `user` (`id`))",
        );
        assert_eq!(error.kind, ErrorKind::ForeignKey);
        assert_eq!(error.message, "other rows still reference this one");
        assert_eq!(error.referenced_table.as_deref(), Some("user"));
    }

    #[test]
    fn mysql_duplicate_entry_carries_the_value_and_the_key() {
        let error = parse_mysql(
            1062,
            "23000",
            "Duplicate entry 'jan@ventia.pl' for key 'user.email_unique'",
        );
        assert_eq!(error.kind, ErrorKind::Unique);
        assert_eq!(error.value.as_deref(), Some("jan@ventia.pl"));
        assert_eq!(error.constraint.as_deref(), Some("email_unique"));
        assert_eq!(error.table.as_deref(), Some("user"));
    }

    #[test]
    fn mysql_duplicate_entry_without_a_qualified_key() {
        // 5.7 does not qualify the key name; 8.0 does.
        let error = parse_mysql(1062, "23000", "Duplicate entry 'x' for key 'email_unique'");
        assert_eq!(error.constraint.as_deref(), Some("email_unique"));
        assert_eq!(error.table, None);
    }

    #[test]
    fn mysql_not_null() {
        let error = parse_mysql(1048, "23000", "Column 'name' cannot be null");
        assert_eq!(error.kind, ErrorKind::NotNull);
        assert_eq!(error.column.as_deref(), Some("name"));
    }

    #[test]
    fn mysql_takes_the_column_from_a_qualified_name() {
        // MariaDB qualifies the column in some messages and not in others.
        // Reading the first quoted run reports the *database* as the column.
        let error = parse_mysql(
            1366,
            "22007",
            "Incorrect integer value: 'nonsense' for column 'shop'.'dbclient_err_child'.'priority' at row 1",
        );
        assert_eq!(error.column.as_deref(), Some("priority"));
        assert_eq!(error.value.as_deref(), Some("nonsense"));
        assert_eq!(error.row, Some(1));
    }

    #[test]
    fn mysql_data_too_long_names_the_column_and_the_row() {
        let error = parse_mysql(1406, "22001", "Data too long for column 'name' at row 4");
        assert_eq!(error.kind, ErrorKind::StringTooLong);
        assert_eq!(error.column.as_deref(), Some("name"));
        assert_eq!(error.row, Some(4));
    }

    #[test]
    fn mysql_out_of_range() {
        let error = parse_mysql(
            1264,
            "22003",
            "Out of range value for column 'priority' at row 1",
        );
        assert_eq!(error.kind, ErrorKind::NumericRange);
        assert_eq!(error.column.as_deref(), Some("priority"));
    }

    #[test]
    fn mysql_bad_datetime_keeps_the_value() {
        let error = parse_mysql(
            1292,
            "22007",
            "Incorrect datetime value: '2026-02-30' for column 'created_at' at row 1",
        );
        assert_eq!(error.kind, ErrorKind::DataType);
        assert_eq!(error.value.as_deref(), Some("2026-02-30"));
        assert_eq!(error.column.as_deref(), Some("created_at"));
        assert_eq!(error.row, Some(1));
    }

    #[test]
    fn mysql_check_constraint() {
        let error = parse_mysql(
            3819,
            "HY000",
            "Check constraint 'chk_priority' is violated.",
        );
        assert_eq!(error.kind, ErrorKind::Check);
        assert_eq!(error.constraint.as_deref(), Some("chk_priority"));
    }

    #[test]
    fn mysql_operational_codes() {
        assert_eq!(
            parse_mysql(1213, "40001", "Deadlock found when trying to get lock").kind,
            ErrorKind::Deadlock
        );
        assert_eq!(
            parse_mysql(1205, "HY000", "Lock wait timeout exceeded").kind,
            ErrorKind::LockTimeout
        );
        assert_eq!(
            parse_mysql(1045, "28000", "Access denied for user 'x'@'y'").kind,
            ErrorKind::Authentication
        );
        assert_eq!(
            parse_mysql(1142, "42000", "SELECT command denied to user").kind,
            ErrorKind::Permission
        );
        assert_eq!(
            parse_mysql(2006, "HY000", "MySQL server has gone away").kind,
            ErrorKind::ConnectionLost
        );
    }

    #[test]
    fn sqlstate_classes_map_sensibly() {
        assert_eq!(kind_from_sqlstate("42601"), ErrorKind::Syntax);
        assert_eq!(kind_from_sqlstate("42P01"), ErrorKind::UndefinedTable);
        assert_eq!(kind_from_sqlstate("42703"), ErrorKind::UndefinedColumn);
        assert_eq!(kind_from_sqlstate("23503"), ErrorKind::ForeignKey);
        assert_eq!(kind_from_sqlstate("23505"), ErrorKind::Unique);
        assert_eq!(kind_from_sqlstate("23502"), ErrorKind::NotNull);
        assert_eq!(kind_from_sqlstate("57014"), ErrorKind::Cancelled);
        assert_eq!(kind_from_sqlstate("25P02"), ErrorKind::TransactionAborted);
        // An unlisted code still lands in the right family.
        assert_eq!(kind_from_sqlstate("42XYZ"), ErrorKind::Syntax);
        assert_eq!(kind_from_sqlstate("08999"), ErrorKind::ConnectionLost);
        assert_eq!(kind_from_sqlstate("ZZZZZ"), ErrorKind::Unknown);
    }

    #[test]
    fn postgres_detail_yields_the_key_and_the_referenced_table() {
        let error = DbError {
            kind: ErrorKind::ForeignKey,
            detail: Some("Key (user_id)=(9999) is not present in table \"user\".".to_string()),
            ..Default::default()
        }
        .enrich_from_detail();

        assert_eq!(error.column.as_deref(), Some("user_id"));
        assert_eq!(error.value.as_deref(), Some("9999"));
        assert_eq!(error.referenced_table.as_deref(), Some("user"));
    }

    #[test]
    fn postgres_detail_for_the_other_direction() {
        let error = DbError {
            detail: Some("Key (id)=(4) is still referenced from table \"inquiry\".".to_string()),
            ..Default::default()
        }
        .enrich_from_detail();
        assert_eq!(error.referenced_table.as_deref(), Some("inquiry"));
        assert_eq!(error.value.as_deref(), Some("4"));
    }

    #[test]
    fn postgres_message_yields_the_identifier_that_is_missing() {
        // PostgreSQL sets `column` for constraint violations and not for this,
        // where the name lives only in the message.
        let error = DbError {
            kind: ErrorKind::UndefinedColumn,
            message: "column \"priorty\" does not exist".into(),
            ..Default::default()
        }
        .enrich_from_message();
        assert_eq!(error.column.as_deref(), Some("priorty"));
        assert_eq!(error.near.as_deref(), Some("priorty"));

        let table = DbError {
            kind: ErrorKind::UndefinedTable,
            message: "relation \"dbclient_err_chil\" does not exist".into(),
            ..Default::default()
        }
        .enrich_from_message();
        assert_eq!(table.table.as_deref(), Some("dbclient_err_chil"));

        let function = DbError {
            kind: ErrorKind::UndefinedFunction,
            message: "function no_such_fn(integer) does not exist".into(),
            ..Default::default()
        }
        .enrich_from_message();
        assert_eq!(function.near.as_deref(), Some("no_such_fn"));
    }

    #[test]
    fn postgres_enrichment_leaves_a_populated_field_alone() {
        let error = DbError {
            kind: ErrorKind::UndefinedColumn,
            message: "column \"a\" does not exist".into(),
            column: Some("b".into()),
            ..Default::default()
        }
        .enrich_from_message();
        assert_eq!(error.column.as_deref(), Some("b"), "the server field wins");
    }

    #[test]
    fn sqlite_messages() {
        let syntax = parse_sqlite(1, "near \"FORM\": syntax error");
        assert_eq!(syntax.kind, ErrorKind::Syntax);
        // The original casing, because this string is searched for in the
        // user's SQL and compared against their identifiers.
        assert_eq!(syntax.near.as_deref(), Some("FORM"));

        let not_null = parse_sqlite(1299, "NOT NULL constraint failed: user.name");
        assert_eq!(not_null.kind, ErrorKind::NotNull);
        assert_eq!(not_null.table.as_deref(), Some("user"));
        assert_eq!(not_null.column.as_deref(), Some("name"));

        let unique = parse_sqlite(2067, "UNIQUE constraint failed: user.email");
        assert_eq!(unique.kind, ErrorKind::Unique);
        assert_eq!(unique.column.as_deref(), Some("email"));

        let composite = parse_sqlite(2067, "UNIQUE constraint failed: t.a, t.b");
        assert_eq!(composite.kind, ErrorKind::Unique);
        assert_eq!(composite.table.as_deref(), Some("t"));

        assert_eq!(
            parse_sqlite(787, "FOREIGN KEY constraint failed").kind,
            ErrorKind::ForeignKey
        );
        assert_eq!(
            parse_sqlite(1, "no such column: statuz").column.as_deref(),
            Some("statuz")
        );
        assert_eq!(
            parse_sqlite(1, "no such table: userz").table.as_deref(),
            Some("userz")
        );
        assert_eq!(
            parse_sqlite(8, "attempt to write a readonly database").kind,
            ErrorKind::ReadOnly
        );
    }

    #[test]
    fn sqlite_offset_is_taken_from_the_message_and_the_echo_dropped() {
        // rusqlite appends `in <the whole statement> at offset N`, which is the
        // only position SQLite offers — and an echo of what the user is already
        // looking at.
        let error = parse_sqlite(
            1,
            "near \"FORM\": syntax error in select * FORM user at offset 9",
        );
        assert_eq!(error.message, "syntax error");
        assert_eq!(error.byte_offset, Some(9));

        let located = error.with_statement("select * FORM user", None, None);
        assert_eq!(located.position, Some(10));
    }

    #[test]
    fn sqlite_offset_converts_from_bytes_to_characters() {
        let sql = "select 'Łódź' FORM t";
        let byte = sql.find("FORM").unwrap() as u32;
        let error = parse_sqlite(
            1,
            &format!("near \"FORM\": syntax error in {sql} at offset {byte}"),
        )
        .with_statement(sql, None, None);
        let position = error.position.unwrap();
        assert_eq!(sql.chars().nth(position as usize - 1), Some('F'));
    }

    #[test]
    fn sqlite_keeps_identifier_casing() {
        let error = parse_sqlite(1, "no such column: userName");
        assert_eq!(error.column.as_deref(), Some("userName"));
        let error = parse_sqlite(1299, "NOT NULL constraint failed: User.fullName");
        assert_eq!(error.table.as_deref(), Some("User"));
        assert_eq!(error.column.as_deref(), Some("fullName"));
    }

    #[test]
    fn local_errors_are_classified_rather_than_shipped_as_prose() {
        assert_eq!(
            classify_local("this connection is read-only, so `delete` was not run").kind,
            ErrorKind::AccessRefused
        );
        assert_eq!(
            classify_local("failed to connect to MariaDB: Connection refused").kind,
            ErrorKind::ConnectionLost
        );
        assert_eq!(
            classify_local("statement cancelled").kind,
            ErrorKind::Cancelled
        );
        assert_eq!(
            classify_local("something else entirely").kind,
            ErrorKind::Unknown
        );
    }

    #[test]
    fn a_position_is_recovered_from_a_quoted_fragment() {
        let sql = "select * FORM users";
        // 1-based, pointing at the F of FORM.
        assert_eq!(recover_position(sql, Some("FORM users"), Some(1)), Some(10));
    }

    #[test]
    fn recovery_uses_the_line_to_disambiguate() {
        let sql = "select id\nfrom a\nwhere id in (select id form b)";
        // "form" also occurs on line 2 as the legitimate keyword; the reported
        // line is what keeps the caret off it.
        let position = recover_position(sql, Some("form b)"), Some(3)).unwrap();
        let prefix: String = sql.chars().take(position as usize - 1).collect();
        assert!(prefix.ends_with("select id "), "landed after: {prefix}");
    }

    #[test]
    fn recovery_shortens_a_truncated_fragment() {
        // The server truncates what it quotes, so an exact match can fail.
        let sql = "select * from users where namez = 1";
        let position =
            recover_position(sql, Some("namez = 1 and something the server cut"), None).unwrap();
        assert!(
            sql[position as usize - 1..].starts_with("namez"),
            "landed on: {}",
            &sql[position as usize - 1..]
        );
    }

    #[test]
    fn recovery_counts_characters_not_bytes() {
        // A caret placed by byte offset drifts on every non-ASCII character
        // before it, which in this project is most of them.
        let sql = "select 'Łódź' FORM t";
        let position = recover_position(sql, Some("FORM"), None).unwrap();
        assert_eq!(sql.chars().nth(position as usize - 1), Some('F'));
    }

    #[test]
    fn recovery_declines_rather_than_guessing() {
        assert_eq!(recover_position("select 1", Some("nowhere"), None), None);
        assert_eq!(recover_position("select 1", None, None), None);
        assert_eq!(recover_position("select 1", Some("   "), None), None);
    }

    #[test]
    fn a_statement_attaches_and_recovers_its_own_position() {
        let error = parse_mysql(
            1064,
            "42000",
            "You have an error in your SQL syntax; ... near 'FORM users' at line 1",
        )
        .with_statement("select * FORM users", Some(2), Some(40));

        assert_eq!(error.position, Some(10));
        assert_eq!(error.statement_index, Some(2));
        assert_eq!(error.statement_offset, Some(40));
    }

    #[test]
    fn a_server_reported_position_is_never_overwritten() {
        let mut error = DbError::new(ErrorKind::Syntax, "syntax error");
        error.position = Some(7);
        error.near = Some("select".into());
        let error = error.with_statement("select * from t", None, None);
        assert_eq!(error.position, Some(7), "the server knows better");
    }

    #[test]
    fn kinds_know_whether_they_are_the_statement_s_fault() {
        assert!(ErrorKind::Syntax.is_statement_fault());
        assert!(ErrorKind::UndefinedColumn.is_statement_fault());
        // A constraint violation is the data's fault, not the statement's, so
        // there is no single token to point at.
        assert!(!ErrorKind::ForeignKey.is_statement_fault());
        assert!(!ErrorKind::Deadlock.is_statement_fault());

        assert!(ErrorKind::Deadlock.is_transient());
        assert!(ErrorKind::LockTimeout.is_transient());
        assert!(!ErrorKind::Syntax.is_transient());
    }
}
