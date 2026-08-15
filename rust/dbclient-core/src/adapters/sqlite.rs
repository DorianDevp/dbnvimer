//! SQLite session adapter.
//!
//! SQLite has no schemas in the SQL sense; attached databases (`main`, `temp`
//! and anything `attach`ed) fill that role, so they are what the sidebar shows.

use crate::protocol::{
    ApplyOutcome, ColumnDesc, PreviewParams, QueryOutput, RowChange, ValueClass,
};
use crate::session::{
    clamp_limit, classify, elapsed_ms, encode_binary, inline_placeholders, validate_filter, Access,
    BackendInfo, BatchSink, CancelHandle, ConnectionSpec, DbSession, DdlKind, ValidationError,
};
use crate::sqlparse;
use anyhow::{anyhow, Context, Result};
use rusqlite::types::{Value as SqlValue, ValueRef};
use rusqlite::Connection;
use serde_json::{json, Value as JsonValue};
use std::collections::BTreeMap;
use std::time::Instant;

pub struct SqliteSession {
    conn: Connection,
    access: Access,
    in_transaction: bool,
    path: String,
    column_cache: BTreeMap<String, Vec<ColumnMeta>>,
}

#[derive(Clone, Debug)]
struct ColumnMeta {
    name: String,
    type_name: String,
    nullable: bool,
    primary: bool,
}

impl SqliteSession {
    pub fn open(spec: &ConnectionSpec) -> Result<Self> {
        let path = spec.require_path()?.to_string();
        let conn = if path == ":memory:" {
            Connection::open_in_memory().context("failed to open in-memory SQLite database")?
        } else {
            Connection::open(&path)
                .with_context(|| format!("failed to open SQLite database at {path}"))?
        };
        conn.execute_batch("pragma foreign_keys = on;").ok();

        Ok(Self {
            conn,
            access: spec.access,
            in_transaction: false,
            path,
            column_cache: BTreeMap::new(),
        })
    }

    fn run(&self, sql: &str, params: &[SqlValue]) -> Result<QueryOutput> {
        let start = Instant::now();
        let mut statement = self
            .conn
            .prepare(sql)
            .with_context(|| format!("failed to prepare: {}", first_line(sql)))?;

        let width = statement.column_count();
        if width == 0 {
            drop(statement);
            let affected = self
                .conn
                .execute(sql, rusqlite::params_from_iter(params.iter()))
                .context("failed to execute statement")?;
            return Ok(QueryOutput {
                columns: Vec::new(),
                rows: Vec::new(),
                affected_rows: affected as u64,
                truncated: false,
                elapsed_ms: elapsed_ms(start),
                notices: Vec::new(),
                kind: Some(sqlparse::leading_keyword(sql)),
            });
        }

        let columns = statement
            .columns()
            .iter()
            .map(|column| {
                let type_name = column.decl_type().unwrap_or("").to_string();
                let class = if type_name.is_empty() {
                    ValueClass::Unknown
                } else {
                    classify(&type_name)
                };
                ColumnDesc::new(column.name(), type_name, class)
            })
            .collect::<Vec<_>>();

        let mut rows = Vec::new();
        let mut cursor = statement
            .query(rusqlite::params_from_iter(params.iter()))
            .context("failed to execute query")?;
        while let Some(row) = cursor.next()? {
            let mut values = Vec::with_capacity(width);
            for index in 0..width {
                values.push(value_to_json(row.get_ref(index)?));
            }
            rows.push(values);
        }

        Ok(QueryOutput {
            columns,
            rows,
            affected_rows: 0,
            truncated: false,
            elapsed_ms: elapsed_ms(start),
            notices: Vec::new(),
            kind: Some(sqlparse::leading_keyword(sql)),
        })
    }

    fn scalar(&self, sql: &str) -> Result<Option<String>> {
        let output = self.run(sql, &[])?;
        Ok(output
            .rows
            .first()
            .and_then(|row| row.first())
            .and_then(|value| value.as_str().map(str::to_string)))
    }

    fn schema_or_main(schema: &str) -> String {
        if schema.is_empty() {
            "main".to_string()
        } else {
            schema.to_string()
        }
    }

    fn column_meta(&mut self, schema: &str, table: &str) -> Result<Vec<ColumnMeta>> {
        let schema = Self::schema_or_main(schema);
        let key = format!("{schema}.{table}");
        if let Some(cached) = self.column_cache.get(&key) {
            return Ok(cached.clone());
        }

        let sql = format!(
            "select name, type, \"notnull\", pk from pragma_table_info({}) order by cid",
            quote_literal(table)
        );
        let sql = sql.replace(
            "pragma_table_info(",
            &format!("{}.pragma_table_info(", quote_ident(&schema)),
        );
        let output = self.run(&sql, &[])?;

        let meta = output
            .rows
            .iter()
            .map(|row| ColumnMeta {
                name: text(row.first()),
                type_name: text(row.get(1)),
                nullable: text(row.get(2)) != "1",
                primary: text(row.get(3)) != "0" && !text(row.get(3)).is_empty(),
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
        let schema = Self::schema_or_main(&params.schema);
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

    fn render_change(&mut self, change: &RowChange) -> Result<(String, Vec<SqlValue>)> {
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
                let schema = Self::schema_or_main(schema);
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
                let schema = Self::schema_or_main(schema);
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
                let schema = Self::schema_or_main(schema);
                let mut values = Vec::new();
                let filters = self.where_clause(&schema, table, pk, expect, &mut values)?;
                Ok((
                    format!(
                        "delete from {}.{} where {}",
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
        values: &mut Vec<SqlValue>,
    ) -> Result<String> {
        let mut filters = Vec::new();
        for (column, value) in pk
            .iter()
            .chain(expect.iter().filter(|(key, _)| !pk.contains_key(*key)))
        {
            let meta = self.meta_for(schema, table, column)?;
            values.push(coerce(value, &meta)?);
            filters.push(format!("{} is ?", quote_ident(column)));
        }
        Ok(filters.join(" and "))
    }
}

impl DbSession for SqliteSession {
    fn backend_info(&mut self) -> Result<BackendInfo> {
        let version = self
            .scalar("select 'SQLite ' || sqlite_version()")?
            .unwrap_or_else(|| "SQLite".to_string());
        Ok(BackendInfo {
            adapter: "sqlite".to_string(),
            server_version: version,
            database: Some(self.path.clone()),
            backend_pid: None,
            access: self.access.as_str().to_string(),
        })
    }

    fn schemas(&mut self) -> Result<Vec<JsonValue>> {
        let output = self.run("select name from pragma_database_list order by seq", &[])?;
        Ok(output
            .rows
            .iter()
            .map(|row| json!({ "name": text(row.first()), "comment": JsonValue::Null }))
            .collect())
    }

    fn tables(&mut self, schema: &str) -> Result<Vec<JsonValue>> {
        let schema = Self::schema_or_main(schema);
        let sql = format!(
            r#"
            select name,
                   case type when 'table' then 'BASE TABLE' else upper(type) end,
                   -1
            from {}.sqlite_master
            where type in ('table', 'view') and name not like 'sqlite_%'
            order by name
            "#,
            quote_ident(&schema)
        );
        let output = self.run(&sql, &[])?;
        Ok(output
            .rows
            .iter()
            .map(|row| {
                json!({
                    "name": text(row.first()),
                    "kind": text(row.get(1)),
                    "estimated_rows": -1,
                    "comment": JsonValue::Null,
                })
            })
            .collect())
    }

    fn columns(&mut self, schema: &str, table: &str) -> Result<Vec<JsonValue>> {
        let schema = Self::schema_or_main(schema);
        let sql = format!(
            "select name, type, \"notnull\", pk, dflt_value, cid from {}.pragma_table_info({}) order by cid",
            quote_ident(&schema),
            quote_literal(table)
        );
        let output = self.run(&sql, &[])?;
        Ok(output
            .rows
            .iter()
            .map(|row| {
                let type_name = text(row.get(1));
                let pk = text(row.get(3));
                json!({
                    "name": text(row.first()),
                    "type": type_name,
                    "class": classify(&type_name).as_str(),
                    "nullable": text(row.get(2)) != "1",
                    "key": if pk != "0" && !pk.is_empty() { "PRI" } else { "" },
                    "default": optional(row.get(4)),
                    "comment": JsonValue::Null,
                    "position": text(row.get(5)).parse::<i64>().unwrap_or(0) + 1,
                })
            })
            .collect())
    }

    fn routines(&mut self, _schema: &str) -> Result<Vec<JsonValue>> {
        // SQLite has no stored routines; triggers are the closest analogue and
        // are surfaced under their own node instead.
        Ok(Vec::new())
    }

    fn indexes(&mut self, schema: &str, table: &str) -> Result<Vec<JsonValue>> {
        let schema = Self::schema_or_main(schema);
        let sql = format!(
            "select name, \"unique\", origin from {}.pragma_index_list({})",
            quote_ident(&schema),
            quote_literal(table)
        );
        let output = self.run(&sql, &[])?;
        let mut indexes = Vec::new();
        for row in &output.rows {
            let name = text(row.first());
            let columns_sql = format!(
                "select group_concat(name, ', ') from {}.pragma_index_info({})",
                quote_ident(&schema),
                quote_literal(&name)
            );
            let columns = self
                .scalar(&columns_sql)
                .unwrap_or_default()
                .unwrap_or_default();
            indexes.push(json!({
                "name": name,
                "unique": text(row.get(1)) == "1",
                "primary": text(row.get(2)) == "pk",
                "definition": format!("({columns})"),
                "columns": columns,
                "size_bytes": 0,
            }));
        }
        Ok(indexes)
    }

    fn foreign_keys(&mut self, schema: &str, table: &str) -> Result<Vec<JsonValue>> {
        let schema = Self::schema_or_main(schema);
        let sql = format!(
            "select id, \"table\", \"from\", \"to\" from {}.pragma_foreign_key_list({})",
            quote_ident(&schema),
            quote_literal(table)
        );
        let output = self.run(&sql, &[])?;
        Ok(output
            .rows
            .iter()
            .map(|row| {
                json!({
                    "name": format!("fk_{}", text(row.first())),
                    "column": text(row.get(2)),
                    "ref_schema": schema.clone(),
                    "ref_table": text(row.get(1)),
                    "ref_column": text(row.get(3)),
                })
            })
            .collect())
    }

    fn referencing_keys(&mut self, schema: &str, table: &str) -> Result<Vec<JsonValue>> {
        let schema = Self::schema_or_main(schema);
        let tables = self.tables(&schema)?;
        let mut found = Vec::new();
        for entry in tables {
            let Some(name) = entry["name"].as_str() else {
                continue;
            };
            if name == table {
                continue;
            }
            for key in self.foreign_keys(&schema, name)? {
                if key["ref_table"].as_str() == Some(table) {
                    found.push(json!({
                        "name": key["name"],
                        "schema": schema.clone(),
                        "table": name,
                        "column": key["column"],
                        "ref_column": key["ref_column"],
                    }));
                }
            }
        }
        Ok(found)
    }

    fn schema_foreign_keys(&mut self, schema: &str) -> Result<Vec<JsonValue>> {
        // SQLite has no catalog of foreign keys, so the per-table pragma is
        // the only source; at least it is a local file.
        let schema = Self::schema_or_main(schema);
        let mut all = Vec::new();
        for entry in self.tables(&schema)? {
            let Some(name) = entry["name"].as_str().map(str::to_string) else {
                continue;
            };
            for key in self.foreign_keys(&schema, &name)? {
                let mut item = key.clone();
                item["table"] = json!(name);
                all.push(item);
            }
        }
        Ok(all)
    }

    fn preview(&mut self, params: &PreviewParams) -> Result<QueryOutput> {
        let sql = self.build_select(params, false)?;
        let limit = clamp_limit(params.limit, 200);
        let mut output = self.run(&sql, &[])?;
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
        let statements = sqlparse::split(sql);
        let mut last = QueryOutput::empty();
        let mut affected = 0u64;

        // SQLite prepares one statement at a time, so scripts are executed
        // statement by statement and the last result set wins.
        for statement in &statements {
            let output = self.run(&statement.text, &[])?;
            affected += output.affected_rows;
            if !output.columns.is_empty() || statements.len() == 1 {
                last = output;
            }
        }
        last.affected_rows = last.affected_rows.max(affected);
        if last.rows.len() as u64 > cap {
            last.truncated = true;
            last.rows.truncate(cap as usize);
        }
        Ok(last)
    }

    fn validate(&mut self, sql: &str) -> Result<Option<ValidationError>> {
        match self.conn.prepare(sql) {
            Ok(_) => Ok(None),
            Err(error) => Ok(Some(ValidationError {
                message: error.to_string(),
                position: None,
            })),
        }
    }

    fn stream_query(&mut self, sql: &str, batch_size: usize, sink: BatchSink<'_>) -> Result<u64> {
        self.enforce_access(sql)?;

        let mut statement = self
            .conn
            .prepare(sql)
            .with_context(|| format!("failed to prepare: {}", first_line(sql)))?;

        let width = statement.column_count();
        let columns = statement
            .columns()
            .iter()
            .map(|column| {
                let type_name = column.decl_type().unwrap_or("").to_string();
                let class = if type_name.is_empty() {
                    ValueClass::Unknown
                } else {
                    classify(&type_name)
                };
                ColumnDesc::new(column.name(), type_name, class)
            })
            .collect::<Vec<_>>();

        let mut cursor = statement.query([]).context("failed to execute query")?;
        let mut batch: Vec<Vec<JsonValue>> = Vec::with_capacity(batch_size);
        let mut total = 0u64;

        while let Some(row) = cursor.next()? {
            let mut values = Vec::with_capacity(width);
            for index in 0..width {
                values.push(value_to_json(row.get_ref(index)?));
            }
            batch.push(values);
            total += 1;

            if batch.len() >= batch_size && !sink(&columns, std::mem::take(&mut batch))? {
                return Ok(total);
            }
        }

        if !batch.is_empty() {
            sink(&columns, batch)?;
        } else if total == 0 {
            // Let the writer emit a header even for an empty result.
            sink(&columns, Vec::new())?;
        }

        Ok(total)
    }

    fn explain(&mut self, sql: &str, _analyze: bool) -> Result<JsonValue> {
        let output = self.run(&format!("explain query plan {sql}"), &[])?;
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
            self.conn.execute_batch("begin")?;
        }

        let mut statements = Vec::new();
        let mut affected = 0u64;
        let sandbox = self.access == Access::Sandbox;

        let outcome = (|| -> Result<()> {
            for change in changes {
                let (sql, values) = self.render_change(change)?;
                let count = self
                    .conn
                    .execute(&sql, rusqlite::params_from_iter(values.iter()))
                    .with_context(|| format!("failed to apply {}", change.label()))?;
                if count == 0 && !matches!(change, RowChange::Insert { .. }) {
                    return Err(anyhow!(
                        "{} on {}.{} matched no rows; the row was changed or removed by someone else",
                        change.label(),
                        change.schema(),
                        change.table()
                    ));
                }
                affected += count as u64;
                statements.push(sql);
            }
            Ok(())
        })();

        match outcome {
            Ok(()) if sandbox => {
                self.conn.execute_batch("rollback")?;
                self.in_transaction = false;
                statements.push("-- sandbox: rolled back".to_string());
            }
            Ok(()) if !already_open => {
                self.conn.execute_batch("commit")?;
                self.in_transaction = false;
            }
            Ok(()) => {}
            Err(error) => {
                let _ = self.conn.execute_batch("rollback");
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
        self.conn.execute_batch("begin")?;
        self.in_transaction = true;
        Ok(())
    }

    fn commit(&mut self) -> Result<()> {
        if !self.in_transaction {
            return Err(anyhow!("no open transaction"));
        }
        self.conn.execute_batch("commit")?;
        self.in_transaction = false;
        Ok(())
    }

    fn rollback(&mut self) -> Result<()> {
        if !self.in_transaction {
            return Err(anyhow!("no open transaction"));
        }
        self.conn.execute_batch("rollback")?;
        self.in_transaction = false;
        Ok(())
    }

    fn in_transaction(&self) -> bool {
        self.in_transaction
    }

    fn ddl(&mut self, kind: DdlKind, schema: &str, name: &str) -> Result<String> {
        let schema = Self::schema_or_main(schema);
        let want = match kind {
            DdlKind::Table => "table",
            DdlKind::View => "view",
            DdlKind::Index => "index",
            DdlKind::Trigger => "trigger",
            DdlKind::Routine => return Err(anyhow!("SQLite has no stored routines")),
        };

        let sql = format!(
            "select sql from {}.sqlite_master where name = {} and type = {}",
            quote_ident(&schema),
            quote_literal(name),
            quote_literal(want)
        );
        let mut ddl = self
            .scalar(&sql)?
            .ok_or_else(|| anyhow!("{want} {schema}.{name} not found"))?;

        if kind == DdlKind::Table {
            let extra = format!(
                "select sql from {}.sqlite_master where tbl_name = {} and type = 'index' and sql is not null order by name",
                quote_ident(&schema),
                quote_literal(name)
            );
            for row in self.run(&extra, &[])?.rows {
                ddl.push_str(&format!(";\n\n{}", text(row.first())));
            }
        }
        Ok(format!("{ddl};"))
    }

    fn column_stats(&mut self, schema: &str, table: &str, column: &str) -> Result<JsonValue> {
        let schema = Self::schema_or_main(schema);
        let meta = self.meta_for(&schema, table, column)?;
        let qualified = format!("{}.{}", quote_ident(&schema), quote_ident(table));
        let quoted = quote_ident(column);
        let class = classify(&meta.type_name);

        let summary = self.run(
            &format!("select count(*), count({quoted}), count(distinct {quoted}) from {qualified}"),
            &[],
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

        if matches!(
            class,
            ValueClass::Number | ValueClass::Temporal | ValueClass::Unknown
        ) {
            let sql = format!("select min({quoted}), max({quoted}) from {qualified}");
            if let Ok(range) = self.run(&sql, &[]) {
                if let Some(values) = range.rows.first() {
                    stats["min"] = json!(text(values.first()));
                    stats["max"] = json!(text(values.get(1)));
                }
            }
        }
        if class == ValueClass::Number {
            let sql = format!("select avg({quoted}) from {qualified}");
            if let Ok(agg) = self.run(&sql, &[]) {
                if let Some(values) = agg.rows.first() {
                    stats["avg"] = json!(text(values.first()));
                }
            }
        }

        let top = self.run(
            &format!(
                "select {quoted}, count(*) from {qualified} group by 1 order by count(*) desc, 1 limit 10"
            ),
            &[],
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
        Err(anyhow!("SQLite is embedded: there are no server sessions"))
    }

    fn locks(&mut self) -> Result<QueryOutput> {
        Err(anyhow!("SQLite is embedded: there is no lock monitor"))
    }

    fn table_sizes(&mut self, schema: &str) -> Result<QueryOutput> {
        let schema = Self::schema_or_main(schema);
        // dbstat is an optional module; fall back to a row count per table.
        let dbstat = format!(
            r#"
            select name as "table",
                   sum(pgsize) as bytes,
                   count(*) as pages
            from {}.dbstat group by name order by sum(pgsize) desc
            "#,
            quote_ident(&schema)
        );
        if let Ok(output) = self.run(&dbstat, &[]) {
            return Ok(output);
        }

        let tables = self.tables(&schema)?;
        let mut rows = Vec::new();
        for entry in tables {
            let Some(name) = entry["name"].as_str() else {
                continue;
            };
            let count = self
                .scalar(&format!(
                    "select count(*) from {}.{}",
                    quote_ident(&schema),
                    quote_ident(name)
                ))
                .ok()
                .flatten()
                .unwrap_or_default();
            rows.push(vec![json!(name), json!(count)]);
        }
        Ok(QueryOutput {
            columns: vec![ColumnDesc::text("table"), ColumnDesc::text("rows")],
            rows,
            affected_rows: 0,
            truncated: false,
            elapsed_ms: 0,
            notices: vec!["dbstat unavailable: showing row counts".to_string()],
            kind: Some("select".to_string()),
        })
    }

    fn unused_indexes(&mut self, schema: &str) -> Result<QueryOutput> {
        let schema = Self::schema_or_main(schema);
        let sql = format!(
            r#"
            select tbl_name as "table", name as "index", '' as uses, '' as size, '' as flags
            from {}.sqlite_master
            where type = 'index' and sql is not null
            order by tbl_name, name
            "#,
            quote_ident(&schema)
        );
        let mut output = self.run(&sql, &[])?;
        output
            .notices
            .push("SQLite does not track index usage counters".to_string());
        Ok(output)
    }

    fn cancel_handle(&mut self) -> CancelHandle {
        CancelHandle::Sqlite(self.conn.get_interrupt_handle())
    }

    fn dialect(&self) -> &'static str {
        "sqlite"
    }

    fn access(&self) -> Access {
        self.access
    }
}

fn coerce(value: &JsonValue, meta: &ColumnMeta) -> Result<SqlValue> {
    if value.is_null() {
        if meta.nullable {
            return Ok(SqlValue::Null);
        }
        return Err(anyhow!("column {} does not allow NULL", meta.name));
    }
    Ok(match value {
        JsonValue::String(text) => SqlValue::Text(text.clone()),
        JsonValue::Number(number) => {
            if let Some(int) = number.as_i64() {
                SqlValue::Integer(int)
            } else {
                SqlValue::Real(number.as_f64().unwrap_or_default())
            }
        }
        JsonValue::Bool(flag) => SqlValue::Integer(i64::from(*flag)),
        _ => return Err(anyhow!("cell value must be scalar")),
    })
}

fn display_literal(value: &SqlValue) -> String {
    match value {
        SqlValue::Null => "null".to_string(),
        SqlValue::Integer(int) => int.to_string(),
        SqlValue::Real(real) => real.to_string(),
        SqlValue::Text(text) => quote_literal(text),
        SqlValue::Blob(bytes) => {
            format!(
                "x'{}'",
                bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
            )
        }
    }
}

fn value_to_json(value: ValueRef<'_>) -> JsonValue {
    match value {
        ValueRef::Null => JsonValue::Null,
        ValueRef::Integer(int) => JsonValue::String(int.to_string()),
        ValueRef::Real(real) => JsonValue::String(format_float(real)),
        ValueRef::Text(bytes) => match std::str::from_utf8(bytes) {
            Ok(text) => JsonValue::String(text.to_string()),
            Err(_) => encode_binary(bytes),
        },
        ValueRef::Blob(bytes) => encode_binary(bytes),
    }
}

fn format_float(value: f64) -> String {
    if value == value.trunc() && value.abs() < 1e15 {
        format!("{value:.1}")
    } else {
        format!("{value}")
    }
}

fn first_line(sql: &str) -> String {
    sql.lines().next().unwrap_or_default().trim().to_string()
}

fn text(value: Option<&JsonValue>) -> String {
    value
        .and_then(|value| value.as_str())
        .unwrap_or_default()
        .to_string()
}

fn optional(value: Option<&JsonValue>) -> JsonValue {
    match value {
        Some(JsonValue::String(text)) => JsonValue::String(text.clone()),
        _ => JsonValue::Null,
    }
}

pub fn quote_ident(identifier: &str) -> String {
    format!("\"{}\"", identifier.replace('"', "\"\""))
}

pub fn quote_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::PreviewParams;

    fn memory_session() -> SqliteSession {
        let spec = ConnectionSpec {
            adapter: "sqlite".to_string(),
            path: Some(":memory:".to_string()),
            ..Default::default()
        };
        let session = SqliteSession::open(&spec).unwrap();
        session
            .conn
            .execute_batch(
                r#"
                create table users (
                    id integer primary key,
                    name text not null,
                    note text,
                    score real
                );
                insert into users (id, name, note, score) values
                    (1, 'Łódź', null, 1.5),
                    (2, 'NULL', 'literal null string', 2.0),
                    (3, 'line
break', 'multi', 3.25);
                "#,
            )
            .unwrap();
        session
    }

    #[test]
    fn preview_orders_by_primary_key() {
        let mut session = memory_session();
        let params = PreviewParams {
            schema: "main".to_string(),
            table: "users".to_string(),
            ..Default::default()
        };
        let output = session.preview(&params).unwrap();
        assert_eq!(output.rows.len(), 3);
        assert_eq!(output.rows[0][0], json!("1"));
        assert_eq!(output.rows[2][0], json!("3"));
    }

    #[test]
    fn distinguishes_sql_null_from_the_string_null() {
        let mut session = memory_session();
        let params = PreviewParams {
            schema: "main".to_string(),
            table: "users".to_string(),
            ..Default::default()
        };
        let output = session.preview(&params).unwrap();
        // Row 1 has a real NULL note, row 2 has the literal text "NULL".
        assert_eq!(output.rows[0][2], JsonValue::Null);
        assert_eq!(output.rows[1][1], json!("NULL"));
    }

    #[test]
    fn truncation_is_reported() {
        let mut session = memory_session();
        let params = PreviewParams {
            schema: "main".to_string(),
            table: "users".to_string(),
            limit: Some(2),
            ..Default::default()
        };
        let output = session.preview(&params).unwrap();
        assert_eq!(output.rows.len(), 2);
        assert!(output.truncated);
    }

    #[test]
    fn applies_updates_with_optimistic_check() {
        let mut session = memory_session();
        let mut set = BTreeMap::new();
        set.insert("name".to_string(), json!("Kraków"));
        let mut pk = BTreeMap::new();
        pk.insert("id".to_string(), json!("1"));
        let mut expect = BTreeMap::new();
        expect.insert("name".to_string(), json!("Łódź"));

        let change = RowChange::Update {
            schema: "main".to_string(),
            table: "users".to_string(),
            set: set.clone(),
            pk: pk.clone(),
            expect,
        };
        let outcome = session.apply_changes(&[change]).unwrap();
        assert_eq!(outcome.affected_rows, 1);

        // A stale expectation must be rejected rather than silently overwrite.
        let mut stale = BTreeMap::new();
        stale.insert("name".to_string(), json!("Łódź"));
        let change = RowChange::Update {
            schema: "main".to_string(),
            table: "users".to_string(),
            set,
            pk,
            expect: stale,
        };
        assert!(session.apply_changes(&[change]).is_err());
    }

    #[test]
    fn rejects_writes_on_read_only_sessions() {
        let spec = ConnectionSpec {
            adapter: "sqlite".to_string(),
            path: Some(":memory:".to_string()),
            access: Access::Read,
            ..Default::default()
        };
        let mut session = SqliteSession::open(&spec).unwrap();
        assert!(session.query("select 1", None).is_ok());
        assert!(session.query("delete from users", None).is_err());
    }

    #[test]
    fn insert_and_delete_round_trip() {
        let mut session = memory_session();
        let mut values = BTreeMap::new();
        values.insert("id".to_string(), json!("42"));
        values.insert("name".to_string(), json!("new"));
        let insert = RowChange::Insert {
            schema: "main".to_string(),
            table: "users".to_string(),
            values,
        };
        assert_eq!(session.apply_changes(&[insert]).unwrap().affected_rows, 1);

        let mut pk = BTreeMap::new();
        pk.insert("id".to_string(), json!("42"));
        let delete = RowChange::Delete {
            schema: "main".to_string(),
            table: "users".to_string(),
            pk,
            expect: BTreeMap::new(),
        };
        assert_eq!(session.apply_changes(&[delete]).unwrap().affected_rows, 1);
    }

    #[test]
    fn sandbox_rolls_writes_back() {
        let spec = ConnectionSpec {
            adapter: "sqlite".to_string(),
            path: Some(":memory:".to_string()),
            access: Access::Sandbox,
            ..Default::default()
        };
        let mut session = SqliteSession::open(&spec).unwrap();
        session
            .conn
            .execute_batch(
                "create table t (id integer primary key, v text);
                            insert into t values (1, 'a');",
            )
            .unwrap();

        let mut set = BTreeMap::new();
        set.insert("v".to_string(), json!("b"));
        let mut pk = BTreeMap::new();
        pk.insert("id".to_string(), json!("1"));
        let change = RowChange::Update {
            schema: "main".to_string(),
            table: "t".to_string(),
            set,
            pk,
            expect: BTreeMap::new(),
        };
        session.apply_changes(&[change]).unwrap();

        let value = session.scalar("select v from t where id = 1").unwrap();
        assert_eq!(value.as_deref(), Some("a"));
    }

    #[test]
    fn table_ddl_includes_indexes() {
        let mut session = memory_session();
        session
            .conn
            .execute_batch("create index users_name_idx on users(name);")
            .unwrap();
        let ddl = session.ddl(DdlKind::Table, "main", "users").unwrap();
        // SQLite normalises the leading keywords when it stores DDL.
        assert!(ddl.to_lowercase().contains("create table users"));
        assert!(ddl.contains("users_name_idx"));
    }

    #[test]
    fn column_stats_reports_distinct_and_top_values() {
        let mut session = memory_session();
        let stats = session.column_stats("main", "users", "name").unwrap();
        assert_eq!(stats["total"], json!("3"));
        assert_eq!(stats["distinct"], json!("3"));
        assert_eq!(stats["top"].as_array().unwrap().len(), 3);
    }
}
