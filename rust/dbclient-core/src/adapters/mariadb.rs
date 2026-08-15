//! MariaDB / MySQL session adapter.

use crate::protocol::{
    ApplyOutcome, ColumnDesc, PreviewParams, QueryOutput, RowChange, ValueClass,
};
use crate::session::{
    clamp_limit, classify, elapsed_ms, encode_binary, inline_placeholders, validate_filter, Access,
    BackendInfo, BatchSink, CancelHandle, ConnectionSpec, DbSession, DdlKind, ValidationError,
};
use crate::sqlparse;
use anyhow::{anyhow, Context, Result};
use mysql::consts::{ColumnFlags, ColumnType};
use mysql::prelude::Queryable;
use mysql::{Conn, Opts, OptsBuilder, Params, Row, Value};
use serde_json::{json, Value as JsonValue};
use std::collections::BTreeMap;
use std::time::Instant;

pub struct MariaDbSession {
    conn: Conn,
    opts: Opts,
    access: Access,
    in_transaction: bool,
    database: Option<String>,
    column_cache: BTreeMap<String, Vec<ColumnMeta>>,
}

#[derive(Clone, Debug)]
struct ColumnMeta {
    name: String,
    type_name: String,
    nullable: bool,
    primary: bool,
}

impl MariaDbSession {
    pub fn open(spec: &ConnectionSpec) -> Result<Self> {
        let mut builder = OptsBuilder::new()
            .ip_or_hostname(Some(spec.host().to_string()))
            .tcp_port(spec.port.unwrap_or(3306))
            .user(Some(spec.user().to_string()))
            .prefer_socket(false);

        if let Some(password) = &spec.password {
            builder = builder.pass(Some(password.clone()));
        }
        if let Some(database) = &spec.database {
            builder = builder.db_name(Some(database.clone()));
        }

        let opts = Opts::from(builder);
        let mut conn = Conn::new(opts.clone()).context("failed to connect to MariaDB")?;

        if let Some(timeout) = spec.statement_timeout_ms {
            // MariaDB uses seconds, MySQL 5.7+ uses milliseconds. Try both and
            // ignore whichever the server rejects.
            let seconds = (timeout as f64 / 1000.0).max(0.001);
            let _ = conn.query_drop(format!("set session max_statement_time = {seconds}"));
            let _ = conn.query_drop(format!("set session max_execution_time = {timeout}"));
        }

        Ok(Self {
            conn,
            opts,
            access: spec.access,
            in_transaction: false,
            database: spec.database.clone(),
            column_cache: BTreeMap::new(),
        })
    }

    fn run(&mut self, sql: &str, params: Params) -> Result<QueryOutput> {
        let start = Instant::now();
        let mut result = self
            .conn
            .exec_iter(sql, params)
            .context("failed to execute query")?;

        let columns = result
            .columns()
            .as_ref()
            .iter()
            .map(|column| {
                let type_name = mysql_type_name(column);
                ColumnDesc::new(
                    column.name_str().into_owned(),
                    &type_name,
                    classify(&type_name),
                )
            })
            .collect::<Vec<_>>();
        let binary_flags = result
            .columns()
            .as_ref()
            .iter()
            .map(is_binary_column)
            .collect::<Vec<_>>();
        let types = result
            .columns()
            .as_ref()
            .iter()
            .map(|column| column.column_type())
            .collect::<Vec<_>>();

        let mut rows = Vec::new();
        for row in result.by_ref() {
            rows.push(row_to_json(row?, columns.len(), &binary_flags, &types));
        }
        let affected = result.affected_rows();
        let warnings = result.warnings();
        drop(result);

        let mut notices = Vec::new();
        if warnings > 0 {
            if let Ok(rows) = self.conn.query::<Row, _>("show warnings") {
                for row in rows {
                    let level: String = row.get(0).unwrap_or_default();
                    let message: String = row.get(2).unwrap_or_default();
                    notices.push(format!("{level}: {message}"));
                }
            }
        }

        Ok(QueryOutput {
            columns,
            rows,
            affected_rows: affected,
            truncated: false,
            elapsed_ms: elapsed_ms(start),
            notices,
            kind: Some(sqlparse::leading_keyword(sql)),
        })
    }

    fn scalar(&mut self, sql: &str) -> Result<Option<String>> {
        let output = self.run(sql, Params::Empty)?;
        Ok(output
            .rows
            .first()
            .and_then(|row| row.first())
            .and_then(|value| value.as_str().map(str::to_string)))
    }

    fn schema_or_current(&mut self, schema: &str) -> String {
        if schema.is_empty() {
            self.database.clone().unwrap_or_default()
        } else {
            schema.to_string()
        }
    }

    fn column_meta(&mut self, schema: &str, table: &str) -> Result<Vec<ColumnMeta>> {
        let key = format!("{schema}.{table}");
        if let Some(cached) = self.column_cache.get(&key) {
            return Ok(cached.clone());
        }

        let output = self.run(
            r#"
            select column_name, column_type, is_nullable, column_key
            from information_schema.columns
            where table_schema = ? and table_name = ?
            order by ordinal_position
            "#,
            Params::Positional(vec![Value::from(schema), Value::from(table)]),
        )?;

        let meta = output
            .rows
            .iter()
            .map(|row| ColumnMeta {
                name: text(row.first()),
                type_name: text(row.get(1)),
                nullable: text(row.get(2)).eq_ignore_ascii_case("yes"),
                primary: text(row.get(3)) == "PRI",
            })
            .collect::<Vec<_>>();

        if meta.is_empty() {
            return Err(anyhow!("unknown table {schema}.{table}"));
        }
        self.column_cache.insert(key, meta.clone());
        Ok(meta)
    }

    fn meta_for(&mut self, schema: &str, table: &str, column: &str) -> Result<ColumnMeta> {
        self.column_meta(schema, table)?
            .into_iter()
            .find(|meta| meta.name == column)
            .ok_or_else(|| anyhow!("unknown column {schema}.{table}.{column}"))
    }

    fn build_select(&mut self, params: &PreviewParams, count_only: bool) -> Result<String> {
        let schema = self.schema_or_current(&params.schema);
        let target = format!("{}.{}", quote_ident(&schema), quote_ident(&params.table));
        let mut sql = if count_only {
            format!("select count(*) from {target}")
        } else {
            format!("select * from {target}")
        };

        if let Some(filter) = params.filter.as_deref().filter(|f| !f.trim().is_empty()) {
            validate_filter(filter)?;
            sql.push_str(&format!(" where {filter}"));
        }
        if count_only {
            return Ok(sql);
        }

        let order = self.order_clause(&schema, params)?;
        if !order.is_empty() {
            sql.push_str(&format!(" order by {order}"));
        }

        let limit = clamp_limit(params.limit, 200);
        sql.push_str(&format!(" limit {}", limit + 1));
        if let Some(offset) = params.offset.filter(|value| *value > 0) {
            sql.push_str(&format!(" offset {offset}"));
        }
        Ok(sql)
    }

    fn order_clause(&mut self, schema: &str, params: &PreviewParams) -> Result<String> {
        if !params.order.is_empty() {
            let meta = self.column_meta(schema, &params.table)?;
            let mut terms = Vec::new();
            for term in &params.order {
                if !meta.iter().any(|column| column.name == term.column) {
                    return Err(anyhow!("unknown sort column {}", term.column));
                }
                terms.push(format!(
                    "{} {}",
                    quote_ident(&term.column),
                    term.dir.as_sql()
                ));
            }
            return Ok(terms.join(", "));
        }

        let primary = self
            .column_meta(schema, &params.table)?
            .into_iter()
            .filter(|column| column.primary)
            .map(|column| quote_ident(&column.name))
            .collect::<Vec<_>>();
        Ok(primary.join(", "))
    }

    /// Columns that hold JSON despite not having a JSON type.
    ///
    /// MariaDB implements `json` as an alias for `longtext` plus a
    /// `json_valid()` check constraint, so `information_schema.columns` reports
    /// `longtext`. Reading the constraint back is the only way to tell a JSON
    /// column from an ordinary text one, and it decides whether the value
    /// inspector offers to pretty print.
    fn json_columns(&mut self, schema: &str, table: &str) -> Vec<String> {
        let sql = r#"
            select constraint_name, check_clause
            from information_schema.check_constraints
            where constraint_schema = ? and table_name = ?
        "#;

        let Ok(output) = self.run(
            sql,
            Params::Positional(vec![Value::from(schema), Value::from(table)]),
        ) else {
            return Vec::new();
        };

        output
            .rows
            .iter()
            .filter_map(|row| {
                let clause = text(row.get(1));
                let lower = clause.to_ascii_lowercase();
                if !lower.contains("json_valid") {
                    return None;
                }
                // `json_valid(`payload`)` — take the quoted identifier.
                clause
                    .split('`')
                    .nth(1)
                    .map(str::to_string)
                    .or_else(|| Some(text(row.first())))
            })
            .collect()
    }

    /// Try each candidate query, returning the first that the server accepts.
    /// Diagnostic views moved between MySQL and MariaDB versions.
    fn first_supported(&mut self, candidates: &[&str]) -> Result<QueryOutput> {
        let mut last: Option<anyhow::Error> = None;
        for sql in candidates {
            match self.run(sql, Params::Empty) {
                Ok(output) => return Ok(output),
                Err(error) => last = Some(error),
            }
        }
        Err(last.unwrap_or_else(|| anyhow!("no supported query for this server")))
    }

    fn render_change(&mut self, change: &RowChange) -> Result<(String, Vec<Value>)> {
        match change {
            RowChange::Update {
                schema,
                table,
                set,
                pk,
                expect,
            } => {
                if pk.is_empty() {
                    return Err(anyhow!("update requires a primary key"));
                }
                if set.is_empty() {
                    return Err(anyhow!("update has no changed columns"));
                }
                let schema = self.schema_or_current(schema);
                let mut values = Vec::new();
                let mut assignments = Vec::new();
                for (column, value) in set {
                    let meta = self.meta_for(&schema, table, column)?;
                    values.push(coerce(value, &meta)?);
                    assignments.push(format!("{} = ?", quote_ident(column)));
                }
                let filters = self.where_clause(&schema, table, pk, expect, &mut values)?;
                Ok((
                    format!(
                        "update {}.{} set {} where {}",
                        quote_ident(&schema),
                        quote_ident(table),
                        assignments.join(", "),
                        filters
                    ),
                    values,
                ))
            }
            RowChange::Insert {
                schema,
                table,
                values: fields,
            } => {
                if fields.is_empty() {
                    return Err(anyhow!("insert has no values"));
                }
                let schema = self.schema_or_current(schema);
                let mut values = Vec::new();
                let mut columns = Vec::new();
                for (column, value) in fields {
                    let meta = self.meta_for(&schema, table, column)?;
                    values.push(coerce(value, &meta)?);
                    columns.push(quote_ident(column));
                }
                let placeholders = vec!["?"; columns.len()].join(", ");
                Ok((
                    format!(
                        "insert into {}.{} ({}) values ({})",
                        quote_ident(&schema),
                        quote_ident(table),
                        columns.join(", "),
                        placeholders
                    ),
                    values,
                ))
            }
            RowChange::Delete {
                schema,
                table,
                pk,
                expect,
            } => {
                if pk.is_empty() {
                    return Err(anyhow!("delete requires a primary key"));
                }
                let schema = self.schema_or_current(schema);
                let mut values = Vec::new();
                let filters = self.where_clause(&schema, table, pk, expect, &mut values)?;
                Ok((
                    format!(
                        "delete from {}.{} where {} limit 1",
                        quote_ident(&schema),
                        quote_ident(table),
                        filters
                    ),
                    values,
                ))
            }
        }
    }

    fn where_clause(
        &mut self,
        schema: &str,
        table: &str,
        pk: &BTreeMap<String, JsonValue>,
        expect: &BTreeMap<String, JsonValue>,
        values: &mut Vec<Value>,
    ) -> Result<String> {
        let mut filters = Vec::new();
        for (column, value) in pk
            .iter()
            .chain(expect.iter().filter(|(key, _)| !pk.contains_key(*key)))
        {
            let meta = self.meta_for(schema, table, column)?;
            values.push(coerce(value, &meta)?);
            filters.push(format!("{} <=> ?", quote_ident(column)));
        }
        Ok(filters.join(" and "))
    }
}

impl DbSession for MariaDbSession {
    fn backend_info(&mut self) -> Result<BackendInfo> {
        let version = self
            .scalar("select concat(@@version, ' ', @@version_comment)")?
            .unwrap_or_else(|| "MariaDB".to_string());
        let database = match self.database.clone() {
            Some(database) => Some(database),
            None => self.scalar("select database()")?,
        };
        self.database = database.clone();
        Ok(BackendInfo {
            adapter: "mariadb".to_string(),
            server_version: version,
            database,
            backend_pid: Some(i64::from(self.conn.connection_id())),
            access: self.access.as_str().to_string(),
        })
    }

    fn schemas(&mut self) -> Result<Vec<JsonValue>> {
        let output = self.run(
            "select schema_name from information_schema.schemata order by schema_name",
            Params::Empty,
        )?;
        Ok(output
            .rows
            .iter()
            .map(|row| json!({ "name": text(row.first()), "comment": JsonValue::Null }))
            .collect())
    }

    fn tables(&mut self, schema: &str) -> Result<Vec<JsonValue>> {
        let schema = self.schema_or_current(schema);
        let output = self.run(
            r#"
            select table_name, table_type, coalesce(table_rows, 0), table_comment
            from information_schema.tables
            where table_schema = ?
            order by table_name
            "#,
            Params::Positional(vec![Value::from(schema)]),
        )?;
        Ok(output
            .rows
            .iter()
            .map(|row| {
                json!({
                    "name": text(row.first()),
                    "kind": text(row.get(1)),
                    "estimated_rows": text(row.get(2)).parse::<i64>().unwrap_or(-1),
                    "comment": optional(row.get(3)),
                })
            })
            .collect())
    }

    fn columns(&mut self, schema: &str, table: &str) -> Result<Vec<JsonValue>> {
        let schema = self.schema_or_current(schema);
        let output = self.run(
            r#"
            select column_name, column_type, is_nullable, column_key,
                   column_default, column_comment, ordinal_position, extra
            from information_schema.columns
            where table_schema = ? and table_name = ?
            order by ordinal_position
            "#,
            Params::Positional(vec![Value::from(schema.clone()), Value::from(table)]),
        )?;

        let json_columns = self.json_columns(&schema, table);

        Ok(output
            .rows
            .iter()
            .map(|row| {
                let name = text(row.first());
                let type_name = text(row.get(1));
                let class = if json_columns.contains(&name) {
                    ValueClass::Json
                } else {
                    classify(&type_name)
                };
                json!({
                    "name": name,
                    "type": type_name,
                    "class": class.as_str(),
                    "nullable": text(row.get(2)).eq_ignore_ascii_case("yes"),
                    "key": text(row.get(3)),
                    "default": optional(row.get(4)),
                    "comment": optional(row.get(5)),
                    "position": text(row.get(6)).parse::<i64>().unwrap_or(0),
                    "extra": text(row.get(7)),
                })
            })
            .collect())
    }

    fn routines(&mut self, schema: &str) -> Result<Vec<JsonValue>> {
        let schema = self.schema_or_current(schema);
        let output = self.run(
            r#"
            select routine_name, routine_type, dtd_identifier, routine_comment
            from information_schema.routines
            where routine_schema = ?
            order by routine_type, routine_name
            "#,
            Params::Positional(vec![Value::from(schema.clone())]),
        )?;

        let args = self.run(
            r#"
            select specific_name,
                   group_concat(concat(parameter_mode, ' ', parameter_name, ' ', dtd_identifier)
                                order by ordinal_position separator ', ')
            from information_schema.parameters
            where specific_schema = ? and ordinal_position > 0
            group by specific_name
            "#,
            Params::Positional(vec![Value::from(schema)]),
        )?;
        let mut arg_map = BTreeMap::new();
        for row in &args.rows {
            arg_map.insert(text(row.first()), text(row.get(1)));
        }

        Ok(output
            .rows
            .iter()
            .map(|row| {
                let name = text(row.first());
                json!({
                    "name": name.clone(),
                    "kind": text(row.get(1)),
                    "returns": optional(row.get(2)),
                    "arguments": arg_map.get(&name).cloned().unwrap_or_default(),
                    "comment": optional(row.get(3)),
                })
            })
            .collect())
    }

    fn indexes(&mut self, schema: &str, table: &str) -> Result<Vec<JsonValue>> {
        let schema = self.schema_or_current(schema);
        let output = self.run(
            r#"
            select index_name,
                   min(non_unique) as non_unique,
                   group_concat(column_name order by seq_in_index separator ', ') as cols,
                   min(index_type) as index_type
            from information_schema.statistics
            where table_schema = ? and table_name = ?
            group by index_name
            order by index_name
            "#,
            Params::Positional(vec![Value::from(schema), Value::from(table)]),
        )?;
        Ok(output
            .rows
            .iter()
            .map(|row| {
                let name = text(row.first());
                json!({
                    "name": name.clone(),
                    "unique": text(row.get(1)) == "0",
                    "primary": name == "PRIMARY",
                    "definition": format!("({}) using {}", text(row.get(2)), text(row.get(3))),
                    "columns": text(row.get(2)),
                    "size_bytes": 0,
                })
            })
            .collect())
    }

    fn foreign_keys(&mut self, schema: &str, table: &str) -> Result<Vec<JsonValue>> {
        let schema = self.schema_or_current(schema);
        let output = self.run(
            r#"
            select constraint_name, column_name,
                   referenced_table_schema, referenced_table_name, referenced_column_name
            from information_schema.key_column_usage
            where table_schema = ? and table_name = ? and referenced_table_name is not null
            order by constraint_name, ordinal_position
            "#,
            Params::Positional(vec![Value::from(schema), Value::from(table)]),
        )?;
        Ok(output
            .rows
            .iter()
            .map(|row| {
                json!({
                    "name": text(row.first()),
                    "column": text(row.get(1)),
                    "ref_schema": text(row.get(2)),
                    "ref_table": text(row.get(3)),
                    "ref_column": text(row.get(4)),
                })
            })
            .collect())
    }

    fn referencing_keys(&mut self, schema: &str, table: &str) -> Result<Vec<JsonValue>> {
        let schema = self.schema_or_current(schema);
        let output = self.run(
            r#"
            select constraint_name, table_schema, table_name, column_name, referenced_column_name
            from information_schema.key_column_usage
            where referenced_table_schema = ? and referenced_table_name = ?
            order by table_name, constraint_name, ordinal_position
            "#,
            Params::Positional(vec![Value::from(schema), Value::from(table)]),
        )?;
        Ok(output
            .rows
            .iter()
            .map(|row| {
                json!({
                    "name": text(row.first()),
                    "schema": text(row.get(1)),
                    "table": text(row.get(2)),
                    "column": text(row.get(3)),
                    "ref_column": text(row.get(4)),
                })
            })
            .collect())
    }

    fn schema_foreign_keys(&mut self, schema: &str) -> Result<Vec<JsonValue>> {
        let schema = self.schema_or_current(schema);
        let output = self.run(
            r#"
            select table_name, column_name, constraint_name,
                   referenced_table_schema, referenced_table_name, referenced_column_name
            from information_schema.key_column_usage
            where table_schema = ? and referenced_table_name is not null
            order by table_name, constraint_name, ordinal_position
            "#,
            Params::Positional(vec![Value::from(schema)]),
        )?;
        Ok(output
            .rows
            .iter()
            .map(|row| {
                json!({
                    "table": text(row.first()),
                    "column": text(row.get(1)),
                    "name": text(row.get(2)),
                    "ref_schema": text(row.get(3)),
                    "ref_table": text(row.get(4)),
                    "ref_column": text(row.get(5)),
                })
            })
            .collect())
    }

    fn preview(&mut self, params: &PreviewParams) -> Result<QueryOutput> {
        let sql = self.build_select(params, false)?;
        let limit = clamp_limit(params.limit, 200);
        let mut output = self.run(&sql, Params::Empty)?;
        output.truncated = output.rows.len() as u64 > limit;
        output.rows.truncate(limit as usize);
        Ok(output)
    }

    fn count(&mut self, params: &PreviewParams) -> Result<u64> {
        let sql = self.build_select(params, true)?;
        Ok(self
            .scalar(&sql)?
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(0))
    }

    fn query(&mut self, sql: &str, limit: Option<u64>) -> Result<QueryOutput> {
        self.enforce_access(sql)?;
        let cap = clamp_limit(limit, 5_000);
        let mut output = self.run(sql, Params::Empty)?;
        if output.rows.len() as u64 > cap {
            output.truncated = true;
            output.rows.truncate(cap as usize);
        }
        Ok(output)
    }

    fn validate(&mut self, sql: &str) -> Result<Option<ValidationError>> {
        // MySQL reports no character position, so the message carries the whole
        // signal — it does at least name the offending identifier.
        match self.conn.prep(sql) {
            Ok(statement) => {
                let _ = self.conn.close(statement);
                Ok(None)
            }
            Err(error) => Ok(Some(ValidationError {
                message: error.to_string(),
                position: None,
            })),
        }
    }

    fn stream_query(&mut self, sql: &str, batch_size: usize, sink: BatchSink<'_>) -> Result<u64> {
        self.enforce_access(sql)?;

        let mut result = self
            .conn
            .exec_iter(sql, Params::Empty)
            .context("failed to execute query")?;

        let columns = result
            .columns()
            .as_ref()
            .iter()
            .map(|column| {
                let type_name = mysql_type_name(column);
                ColumnDesc::new(
                    column.name_str().into_owned(),
                    &type_name,
                    classify(&type_name),
                )
            })
            .collect::<Vec<_>>();
        let binary_flags = result
            .columns()
            .as_ref()
            .iter()
            .map(is_binary_column)
            .collect::<Vec<_>>();
        let types = result
            .columns()
            .as_ref()
            .iter()
            .map(|column| column.column_type())
            .collect::<Vec<_>>();

        let mut batch: Vec<Vec<JsonValue>> = Vec::with_capacity(batch_size);
        let mut total = 0u64;

        for row in result.by_ref() {
            batch.push(row_to_json(row?, columns.len(), &binary_flags, &types));
            total += 1;

            if batch.len() >= batch_size && !sink(&columns, std::mem::take(&mut batch))? {
                return Ok(total);
            }
        }

        if !batch.is_empty() {
            sink(&columns, batch)?;
        } else if total == 0 {
            sink(&columns, Vec::new())?;
        }

        Ok(total)
    }

    fn explain(&mut self, sql: &str, analyze: bool) -> Result<JsonValue> {
        if analyze {
            self.enforce_access(sql)?;
        }
        // MariaDB 10.1+ and MySQL 8 both understand `explain format=json`.
        // `analyze` is MariaDB's flavour of `explain analyze`.
        let attempts: Vec<String> = if analyze {
            vec![
                format!("analyze format=json {sql}"),
                format!("explain analyze {sql}"),
                format!("explain format=json {sql}"),
            ]
        } else {
            vec![
                format!("explain format=json {sql}"),
                format!("explain {sql}"),
            ]
        };

        let wrap = analyze && !self.in_transaction;
        if wrap {
            let _ = self.conn.query_drop("start transaction");
        }

        let mut last: Option<anyhow::Error> = None;
        let mut found: Option<QueryOutput> = None;
        for attempt in &attempts {
            match self.run(attempt, Params::Empty) {
                Ok(output) => {
                    found = Some(output);
                    break;
                }
                Err(error) => last = Some(error),
            }
        }

        if wrap {
            let _ = self.conn.query_drop("rollback");
        }

        let output = found.ok_or_else(|| last.unwrap_or_else(|| anyhow!("explain failed")))?;
        let raw = output
            .rows
            .first()
            .and_then(|row| row.first())
            .and_then(|value| value.as_str())
            .unwrap_or_default();

        if let Ok(plan) = serde_json::from_str::<JsonValue>(raw) {
            return Ok(json!({ "format": "mysql-json", "plan": plan }));
        }
        Ok(json!({ "format": "table", "table": {
            "columns": output.columns,
            "rows": output.rows,
        }}))
    }

    fn apply_changes(&mut self, changes: &[RowChange]) -> Result<ApplyOutcome> {
        if self.access == Access::Read {
            return Err(anyhow!("connection is read-only"));
        }

        let already_open = self.in_transaction;
        if !already_open {
            self.conn.query_drop("start transaction")?;
        }

        let mut statements = Vec::new();
        let mut affected = 0u64;
        let sandbox = self.access == Access::Sandbox;

        let outcome = (|| -> Result<()> {
            for change in changes {
                let (sql, values) = self.render_change(change)?;
                let result = self
                    .conn
                    .exec_iter(sql.as_str(), Params::Positional(values))
                    .with_context(|| format!("failed to apply {}", change.label()))?;
                let count = result.affected_rows();
                drop(result);
                if count == 0 && !matches!(change, RowChange::Insert { .. }) {
                    return Err(anyhow!(
                        "{} on {}.{} matched no rows; the row was changed or removed by someone else",
                        change.label(),
                        change.schema(),
                        change.table()
                    ));
                }
                affected += count;
                statements.push(sql);
            }
            Ok(())
        })();

        match outcome {
            Ok(()) if sandbox => {
                self.conn.query_drop("rollback")?;
                self.in_transaction = false;
                statements.push("-- sandbox: rolled back".to_string());
            }
            Ok(()) if !already_open => {
                self.conn.query_drop("commit")?;
                self.in_transaction = false;
            }
            Ok(()) => {}
            Err(error) => {
                let _ = self.conn.query_drop("rollback");
                self.in_transaction = false;
                return Err(error);
            }
        }

        Ok(ApplyOutcome {
            applied: changes.len(),
            affected_rows: affected,
            statements,
        })
    }

    fn preview_changes(&mut self, changes: &[RowChange]) -> Result<Vec<String>> {
        let mut statements = Vec::new();
        for change in changes {
            let (sql, values) = self.render_change(change)?;
            let literals = values.iter().map(display_literal).collect::<Vec<_>>();
            statements.push(format!("{};", inline_placeholders(&sql, &literals, '?')));
        }
        Ok(statements)
    }

    fn begin(&mut self) -> Result<()> {
        if self.in_transaction {
            return Err(anyhow!("a transaction is already open"));
        }
        self.conn.query_drop("start transaction")?;
        self.in_transaction = true;
        Ok(())
    }

    fn commit(&mut self) -> Result<()> {
        if !self.in_transaction {
            return Err(anyhow!("no open transaction"));
        }
        self.conn.query_drop("commit")?;
        self.in_transaction = false;
        Ok(())
    }

    fn rollback(&mut self) -> Result<()> {
        if !self.in_transaction {
            return Err(anyhow!("no open transaction"));
        }
        self.conn.query_drop("rollback")?;
        self.in_transaction = false;
        Ok(())
    }

    fn in_transaction(&self) -> bool {
        self.in_transaction
    }

    fn ddl(&mut self, kind: DdlKind, schema: &str, name: &str) -> Result<String> {
        let schema = self.schema_or_current(schema);
        let qualified = format!("{}.{}", quote_ident(&schema), quote_ident(name));
        let (sql, column) = match kind {
            DdlKind::Table => (format!("show create table {qualified}"), 1),
            DdlKind::View => (format!("show create view {qualified}"), 1),
            DdlKind::Trigger => (format!("show create trigger {qualified}"), 2),
            DdlKind::Index => {
                let indexes = self.indexes(&schema, name)?;
                return Ok(indexes
                    .iter()
                    .map(|index| {
                        format!(
                            "-- {}\n{}",
                            index["name"].as_str().unwrap_or_default(),
                            index["definition"].as_str().unwrap_or_default()
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("\n\n"));
            }
            DdlKind::Routine => {
                for statement in ["procedure", "function"] {
                    let sql = format!("show create {statement} {qualified}");
                    if let Ok(output) = self.run(&sql, Params::Empty) {
                        if let Some(row) = output.rows.first() {
                            let body = text(row.get(2));
                            if !body.is_empty() {
                                return Ok(body);
                            }
                        }
                    }
                }
                return Err(anyhow!("routine {schema}.{name} not found"));
            }
        };

        let output = self.run(&sql, Params::Empty)?;
        output
            .rows
            .first()
            .map(|row| text(row.get(column)))
            .filter(|value| !value.is_empty())
            .ok_or_else(|| anyhow!("no DDL returned for {schema}.{name}"))
    }

    fn column_stats(&mut self, schema: &str, table: &str, column: &str) -> Result<JsonValue> {
        let schema = self.schema_or_current(schema);
        let meta = self.meta_for(&schema, table, column)?;
        let qualified = format!("{}.{}", quote_ident(&schema), quote_ident(table));
        let quoted = quote_ident(column);
        let class = classify(&meta.type_name);

        let summary = self.run(
            &format!("select count(*), count({quoted}), count(distinct {quoted}) from {qualified}"),
            Params::Empty,
        )?;
        let row = summary
            .rows
            .first()
            .cloned()
            .unwrap_or_else(|| vec![JsonValue::Null; 3]);

        let mut stats = json!({
            "column": column,
            "type": meta.type_name,
            "class": class.as_str(),
            "total": text(row.first()),
            "non_null": text(row.get(1)),
            "distinct": text(row.get(2)),
        });

        if matches!(class, ValueClass::Number | ValueClass::Temporal) {
            let sql = format!("select min({quoted}), max({quoted}) from {qualified}");
            if let Ok(range) = self.run(&sql, Params::Empty) {
                if let Some(values) = range.rows.first() {
                    stats["min"] = json!(text(values.first()));
                    stats["max"] = json!(text(values.get(1)));
                }
            }
            if class == ValueClass::Number {
                let sql = format!("select avg({quoted}), stddev_pop({quoted}) from {qualified}");
                if let Ok(agg) = self.run(&sql, Params::Empty) {
                    if let Some(values) = agg.rows.first() {
                        stats["avg"] = json!(text(values.first()));
                        stats["stddev"] = json!(text(values.get(1)));
                    }
                }
            }
        }

        let top = self.run(
            &format!(
                "select {quoted}, count(*) from {qualified} group by 1 order by count(*) desc, 1 limit 10"
            ),
            Params::Empty,
        )?;
        stats["top"] = JsonValue::Array(
            top.rows
                .iter()
                .map(|row| json!({ "value": optional(row.first()), "count": text(row.get(1)) }))
                .collect(),
        );

        Ok(stats)
    }

    fn activity(&mut self) -> Result<QueryOutput> {
        self.first_supported(&[
            r#"
            select id, user, db, host, command, time, state,
                   left(replace(replace(coalesce(info, ''), '\n', ' '), '\t', ' '), 200) as query
            from information_schema.processlist
            where id <> connection_id()
            order by time desc
            "#,
            "show full processlist",
        ])
    }

    fn locks(&mut self) -> Result<QueryOutput> {
        self.first_supported(&[
            // MySQL 8.0 / MariaDB 10.6+
            r#"
            select r.trx_mysql_thread_id as blocked_pid,
                   left(r.trx_query, 120) as blocked_query,
                   b.trx_mysql_thread_id as blocking_pid,
                   left(b.trx_query, 120) as blocking_query,
                   timestampdiff(second, r.trx_wait_started, now()) as waited_seconds
            from performance_schema.data_lock_waits w
            join information_schema.innodb_trx r on r.trx_id = w.requesting_engine_transaction_id
            join information_schema.innodb_trx b on b.trx_id = w.blocking_engine_transaction_id
            "#,
            // MariaDB 10.5 and older
            r#"
            select r.trx_mysql_thread_id as blocked_pid,
                   left(r.trx_query, 120) as blocked_query,
                   b.trx_mysql_thread_id as blocking_pid,
                   left(b.trx_query, 120) as blocking_query,
                   timestampdiff(second, r.trx_wait_started, now()) as waited_seconds
            from information_schema.innodb_lock_waits w
            join information_schema.innodb_trx r on r.trx_id = w.requesting_trx_id
            join information_schema.innodb_trx b on b.trx_id = w.blocking_trx_id
            "#,
            // Last resort: whatever the process list says is waiting.
            r#"
            select id as blocked_pid, left(coalesce(info, ''), 120) as blocked_query,
                   null as blocking_pid, '' as blocking_query, time as waited_seconds
            from information_schema.processlist
            where state like '%lock%'
            "#,
        ])
    }

    fn table_sizes(&mut self, schema: &str) -> Result<QueryOutput> {
        let schema = self.schema_or_current(schema);
        self.run(
            r#"
            select table_name as `table`,
                   format(round((data_length + index_length) / 1024 / 1024, 1), 1) as total_mb,
                   format(round(data_length / 1024 / 1024, 1), 1) as data_mb,
                   format(round(index_length / 1024 / 1024, 1), 1) as index_mb,
                   table_rows as est_rows,
                   (data_length + index_length) as total_bytes
            from information_schema.tables
            where table_schema = ?
            order by (data_length + index_length) desc
            "#,
            Params::Positional(vec![Value::from(schema)]),
        )
    }

    fn unused_indexes(&mut self, schema: &str) -> Result<QueryOutput> {
        let schema = self.schema_or_current(schema);
        let quoted = quote_literal(&schema);
        self.first_supported(&[
            &format!(
                r#"
                select object_name as `table`, index_name as `index`,
                       count_star as uses, '' as size, '' as flags
                from performance_schema.table_io_waits_summary_by_index_usage
                where object_schema = {quoted} and index_name is not null
                  and index_name <> 'PRIMARY' and count_star = 0
                order by object_name, index_name
                "#
            ),
            &format!(
                r#"
                select table_name as `table`, index_name as `index`,
                       '' as uses, '' as size,
                       case when non_unique = 0 then 'unique' else '' end as flags
                from information_schema.statistics
                where table_schema = {quoted} and index_name <> 'PRIMARY'
                group by table_name, index_name, non_unique
                order by table_name, index_name
                "#
            ),
        ])
    }

    fn cancel_handle(&mut self) -> CancelHandle {
        CancelHandle::MySql {
            opts: Box::new(self.opts.clone()),
            connection_id: self.conn.connection_id(),
        }
    }

    fn dialect(&self) -> &'static str {
        "mariadb"
    }

    fn access(&self) -> Access {
        self.access
    }
}

fn coerce(value: &JsonValue, meta: &ColumnMeta) -> Result<Value> {
    if value.is_null() {
        if meta.nullable {
            return Ok(Value::NULL);
        }
        return Err(anyhow!("column {} does not allow NULL", meta.name));
    }
    let text = match value {
        JsonValue::String(value) => value.clone(),
        JsonValue::Number(value) => value.to_string(),
        JsonValue::Bool(value) => {
            if *value {
                "1".to_string()
            } else {
                "0".to_string()
            }
        }
        _ => return Err(anyhow!("cell value must be scalar")),
    };

    if classify(&meta.type_name) == ValueClass::Number && text.parse::<f64>().is_err() {
        return Err(anyhow!(
            "expected a numeric value for {} ({})",
            meta.name,
            meta.type_name
        ));
    }
    Ok(Value::Bytes(text.into_bytes()))
}

/// Render a bound value the way it will appear in the executed statement.
fn display_literal(value: &Value) -> String {
    match value {
        Value::NULL => "null".to_string(),
        Value::Bytes(bytes) => match std::str::from_utf8(bytes) {
            Ok(text) => quote_literal(text),
            Err(_) => format!(
                "x'{}'",
                bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
            ),
        },
        other => format!("{other:?}"),
    }
}

fn is_binary_column(column: &mysql::Column) -> bool {
    // Character set 63 is `binary`; text columns carry a real collation.
    column.character_set() == 63
        && matches!(
            column.column_type(),
            ColumnType::MYSQL_TYPE_BLOB
                | ColumnType::MYSQL_TYPE_TINY_BLOB
                | ColumnType::MYSQL_TYPE_MEDIUM_BLOB
                | ColumnType::MYSQL_TYPE_LONG_BLOB
                | ColumnType::MYSQL_TYPE_STRING
                | ColumnType::MYSQL_TYPE_VAR_STRING
                | ColumnType::MYSQL_TYPE_VARCHAR
                | ColumnType::MYSQL_TYPE_GEOMETRY
        )
}

fn mysql_type_name(column: &mysql::Column) -> String {
    let unsigned = column.flags().contains(ColumnFlags::UNSIGNED_FLAG);
    let binary = column.character_set() == 63;
    let base = match column.column_type() {
        ColumnType::MYSQL_TYPE_TINY => "tinyint",
        ColumnType::MYSQL_TYPE_SHORT => "smallint",
        ColumnType::MYSQL_TYPE_INT24 => "mediumint",
        ColumnType::MYSQL_TYPE_LONG => "int",
        ColumnType::MYSQL_TYPE_LONGLONG => "bigint",
        ColumnType::MYSQL_TYPE_FLOAT => "float",
        ColumnType::MYSQL_TYPE_DOUBLE => "double",
        ColumnType::MYSQL_TYPE_NEWDECIMAL | ColumnType::MYSQL_TYPE_DECIMAL => "decimal",
        ColumnType::MYSQL_TYPE_DATE | ColumnType::MYSQL_TYPE_NEWDATE => "date",
        ColumnType::MYSQL_TYPE_TIME | ColumnType::MYSQL_TYPE_TIME2 => "time",
        ColumnType::MYSQL_TYPE_DATETIME | ColumnType::MYSQL_TYPE_DATETIME2 => "datetime",
        ColumnType::MYSQL_TYPE_TIMESTAMP | ColumnType::MYSQL_TYPE_TIMESTAMP2 => "timestamp",
        ColumnType::MYSQL_TYPE_YEAR => "year",
        ColumnType::MYSQL_TYPE_JSON => "json",
        ColumnType::MYSQL_TYPE_BIT => "bit",
        ColumnType::MYSQL_TYPE_ENUM => "enum",
        ColumnType::MYSQL_TYPE_SET => "set",
        ColumnType::MYSQL_TYPE_GEOMETRY => "geometry",
        ColumnType::MYSQL_TYPE_TINY_BLOB => {
            return if binary { "tinyblob" } else { "tinytext" }.to_string()
        }
        ColumnType::MYSQL_TYPE_MEDIUM_BLOB => {
            return if binary { "mediumblob" } else { "mediumtext" }.to_string()
        }
        ColumnType::MYSQL_TYPE_LONG_BLOB => {
            return if binary { "longblob" } else { "longtext" }.to_string()
        }
        ColumnType::MYSQL_TYPE_BLOB => return if binary { "blob" } else { "text" }.to_string(),
        ColumnType::MYSQL_TYPE_VAR_STRING | ColumnType::MYSQL_TYPE_VARCHAR => {
            return if binary { "varbinary" } else { "varchar" }.to_string()
        }
        ColumnType::MYSQL_TYPE_STRING => return if binary { "binary" } else { "char" }.to_string(),
        ColumnType::MYSQL_TYPE_NULL => "null",
        _ => "unknown",
    };

    if unsigned && base.contains("int") {
        format!("{base} unsigned")
    } else {
        base.to_string()
    }
}

fn row_to_json(row: Row, width: usize, binary: &[bool], types: &[ColumnType]) -> Vec<JsonValue> {
    (0..width)
        .map(|index| match row.as_ref(index) {
            Some(value) => value_to_json(
                value,
                binary.get(index).copied().unwrap_or(false),
                types.get(index).copied(),
            ),
            None => JsonValue::Null,
        })
        .collect()
}

fn value_to_json(value: &Value, binary: bool, column_type: Option<ColumnType>) -> JsonValue {
    match value {
        Value::NULL => JsonValue::Null,
        Value::Bytes(bytes) => {
            if binary {
                return encode_binary(bytes);
            }
            match std::str::from_utf8(bytes) {
                Ok(text) => JsonValue::String(text.to_string()),
                Err(_) => encode_binary(bytes),
            }
        }
        Value::Int(value) => JsonValue::String(value.to_string()),
        Value::UInt(value) => JsonValue::String(value.to_string()),
        Value::Float(value) => JsonValue::String(format_float(f64::from(*value))),
        Value::Double(value) => JsonValue::String(format_float(*value)),
        Value::Date(year, month, day, hour, minute, second, micros) => {
            // Only render the parts the column actually has, so a DATE column
            // no longer shows a fake `00:00:00.000000`.
            let date = format!("{year:04}-{month:02}-{day:02}");
            if matches!(
                column_type,
                Some(ColumnType::MYSQL_TYPE_DATE) | Some(ColumnType::MYSQL_TYPE_NEWDATE)
            ) {
                return JsonValue::String(date);
            }
            let mut out = format!("{date} {hour:02}:{minute:02}:{second:02}");
            if *micros > 0 {
                out.push_str(&format!(".{micros:06}"));
            }
            JsonValue::String(out)
        }
        Value::Time(negative, days, hours, minutes, seconds, micros) => {
            let sign = if *negative { "-" } else { "" };
            let total_hours = u32::from(*hours) + days * 24;
            let mut out = format!("{sign}{total_hours:02}:{minutes:02}:{seconds:02}");
            if *micros > 0 {
                out.push_str(&format!(".{micros:06}"));
            }
            JsonValue::String(out)
        }
    }
}

fn format_float(value: f64) -> String {
    if value == value.trunc() && value.abs() < 1e15 {
        format!("{value:.0}")
    } else {
        format!("{value}")
    }
}

fn text(value: Option<&JsonValue>) -> String {
    value
        .and_then(|value| value.as_str())
        .unwrap_or_default()
        .to_string()
}

fn optional(value: Option<&JsonValue>) -> JsonValue {
    match value {
        Some(JsonValue::String(text)) if !text.is_empty() => JsonValue::String(text.clone()),
        _ => JsonValue::Null,
    }
}

pub fn quote_ident(identifier: &str) -> String {
    format!("`{}`", identifier.replace('`', "``"))
}

pub fn quote_literal(value: &str) -> String {
    format!("'{}'", value.replace('\\', "\\\\").replace('\'', "''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_identifiers() {
        assert_eq!(quote_ident("users"), "`users`");
        assert_eq!(quote_ident("we`ird"), "`we``ird`");
    }

    #[test]
    fn quotes_literals() {
        assert_eq!(quote_literal("it's"), "'it''s'");
        assert_eq!(quote_literal(r"back\slash"), r"'back\\slash'");
    }

    #[test]
    fn formats_dates_without_fake_precision() {
        let value = Value::Date(2025, 5, 29, 0, 0, 0, 0);
        assert_eq!(
            value_to_json(&value, false, Some(ColumnType::MYSQL_TYPE_DATE)),
            json!("2025-05-29")
        );
        assert_eq!(
            value_to_json(&value, false, Some(ColumnType::MYSQL_TYPE_DATETIME)),
            json!("2025-05-29 00:00:00")
        );
        let precise = Value::Date(2025, 5, 29, 12, 30, 15, 123456);
        assert_eq!(
            value_to_json(&precise, false, Some(ColumnType::MYSQL_TYPE_DATETIME)),
            json!("2025-05-29 12:30:15.123456")
        );
    }

    #[test]
    fn renders_binary_as_hex() {
        let value = Value::Bytes(vec![0x00, 0xff, 0x10]);
        assert_eq!(value_to_json(&value, true, None), json!("\\x00ff10"));
    }

    #[test]
    fn keeps_utf8_text() {
        let value = Value::Bytes("Łódź żółć".as_bytes().to_vec());
        assert_eq!(value_to_json(&value, false, None), json!("Łódź żółć"));
    }

    #[test]
    fn formats_time_beyond_a_day() {
        let value = Value::Time(false, 2, 3, 4, 5, 0);
        assert_eq!(value_to_json(&value, false, None), json!("51:04:05"));
    }
}
