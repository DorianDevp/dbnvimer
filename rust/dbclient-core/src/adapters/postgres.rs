//! PostgreSQL session adapter.
//!
//! Values are fetched with the simple query protocol, which returns every
//! column as text. That sidesteps the "cannot decode type X" class of bugs
//! entirely: arrays, ranges, enums, `numeric(38,10)`, custom domains and
//! extension types all render correctly without a `FromSql` impl per type, and
//! wide numerics keep full precision instead of being squeezed through `f64`.
//! Column types come from a describe-only `prepare`, so the UI still knows how
//! to align and format each column.

use crate::protocol::{
    ApplyOutcome, ColumnDesc, PreviewParams, QueryOutput, RowChange, ValueClass,
};
use crate::session::{
    clamp_limit, classify, elapsed_ms, inline_placeholders, validate_filter, Access, BackendInfo,
    BatchSink, CancelHandle, ConnectionSpec, DbSession, DdlKind, ValidationError,
};
use crate::sqlparse;
use anyhow::{anyhow, Context, Result};
use postgres::types::ToSql;
use postgres::{Client, NoTls, SimpleQueryMessage};
use serde_json::{json, Value as JsonValue};
use std::collections::BTreeMap;
use std::time::Instant;

pub struct PostgresSession {
    client: Client,
    access: Access,
    in_transaction: bool,
    database: Option<String>,
    /// Cached column metadata, keyed by `schema.table`.
    column_cache: BTreeMap<String, Vec<ColumnMeta>>,
}

#[derive(Clone, Debug)]
struct ColumnMeta {
    name: String,
    type_name: String,
    nullable: bool,
    primary: bool,
}

impl PostgresSession {
    pub fn open(spec: &ConnectionSpec) -> Result<Self> {
        let mut params: Vec<String> = vec![
            format!("host={}", escape_param(spec.host())),
            format!("port={}", spec.port.unwrap_or(5432)),
        ];
        if !spec.user().is_empty() {
            params.push(format!("user={}", escape_param(spec.user())));
        }
        if let Some(password) = &spec.password {
            params.push(format!("password={}", escape_param(password)));
        }
        if let Some(database) = &spec.database {
            params.push(format!("dbname={}", escape_param(database)));
        }
        params.push("application_name=dbclient.nvim".to_string());
        for (key, value) in &spec.options {
            params.push(format!("{}={}", key, escape_param(value)));
        }

        let mut client =
            Client::connect(&params.join(" "), NoTls).context("failed to connect to PostgreSQL")?;

        if let Some(timeout) = spec.statement_timeout_ms {
            let _ = client.batch_execute(&format!("set statement_timeout = {timeout}"));
        }

        Ok(Self {
            client,
            access: spec.access,
            in_transaction: false,
            database: spec.database.clone(),
            column_cache: BTreeMap::new(),
        })
    }

    /// Run a statement through the simple protocol and collect rows as text.
    fn simple(&mut self, sql: &str) -> Result<QueryOutput> {
        let start = Instant::now();
        let described = self.describe(sql);
        let messages = self
            .client
            .simple_query(sql)
            .context("failed to execute query")?;

        let mut columns: Vec<ColumnDesc> = described.unwrap_or_default();
        let mut rows: Vec<Vec<JsonValue>> = Vec::new();
        let mut affected = 0u64;

        for message in messages {
            match message {
                SimpleQueryMessage::Row(row) => {
                    if columns.is_empty() {
                        columns = row
                            .columns()
                            .iter()
                            .map(|column| ColumnDesc::text(column.name()))
                            .collect();
                    }
                    let width = columns.len();
                    let mut values = Vec::with_capacity(width);
                    for index in 0..width {
                        values.push(match row.get(index) {
                            Some(text) => JsonValue::String(text.to_string()),
                            None => JsonValue::Null,
                        });
                    }
                    rows.push(values);
                }
                SimpleQueryMessage::CommandComplete(count) => affected = affected.max(count),
                _ => {}
            }
        }

        Ok(QueryOutput {
            columns,
            rows,
            affected_rows: affected,
            truncated: false,
            elapsed_ms: elapsed_ms(start),
            notices: Vec::new(),
            kind: Some(sqlparse::leading_keyword(sql)),
        })
    }

    /// Ask the server for column types without executing the statement.
    fn describe(&mut self, sql: &str) -> Option<Vec<ColumnDesc>> {
        let statement = self.client.prepare(sql).ok()?;
        let columns = statement
            .columns()
            .iter()
            .map(|column| {
                let type_name = column.type_().name().to_string();
                ColumnDesc::new(column.name(), &type_name, classify(&type_name))
            })
            .collect::<Vec<_>>();
        if columns.is_empty() {
            None
        } else {
            Some(columns)
        }
    }

    fn scalar(&mut self, sql: &str) -> Result<Option<String>> {
        let output = self.simple(sql)?;
        Ok(output
            .rows
            .first()
            .and_then(|row| row.first())
            .and_then(|value| value.as_str().map(str::to_string)))
    }

    fn column_meta(&mut self, schema: &str, table: &str) -> Result<Vec<ColumnMeta>> {
        let key = format!("{schema}.{table}");
        if let Some(cached) = self.column_cache.get(&key) {
            return Ok(cached.clone());
        }

        let sql = format!(
            r#"
            select a.attname,
                   format_type(a.atttypid, a.atttypmod),
                   not a.attnotnull,
                   coalesce(pk.is_pk, false)
            from pg_attribute a
            join pg_class c on c.oid = a.attrelid
            join pg_namespace n on n.oid = c.relnamespace
            left join (
                select unnest(i.indkey) as attnum, i.indrelid
                from pg_index i
                where i.indisprimary
            ) pkcols on pkcols.indrelid = c.oid and pkcols.attnum = a.attnum
            left join lateral (select true as is_pk where pkcols.attnum is not null) pk on true
            where n.nspname = {} and c.relname = {} and a.attnum > 0 and not a.attisdropped
            order by a.attnum
            "#,
            quote_literal(schema),
            quote_literal(table)
        );

        let output = self.simple(&sql)?;
        let meta = output
            .rows
            .iter()
            .map(|row| ColumnMeta {
                name: text(row.first()),
                type_name: text(row.get(1)),
                nullable: text(row.get(2)) == "t",
                primary: text(row.get(3)) == "t",
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
        let mut sql = if count_only {
            format!(
                "select count(*) from {}.{}",
                quote_ident(&params.schema),
                quote_ident(&params.table)
            )
        } else {
            format!(
                "select * from {}.{}",
                quote_ident(&params.schema),
                quote_ident(&params.table)
            )
        };

        if let Some(filter) = params.filter.as_deref().filter(|f| !f.trim().is_empty()) {
            validate_filter(filter)?;
            sql.push_str(&format!(" where {filter}"));
        }

        if count_only {
            return Ok(sql);
        }

        let order = self.order_clause(params)?;
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

    /// Explicit sort, falling back to the primary key so pagination and
    /// refreshes are stable instead of returning rows in heap order.
    fn order_clause(&mut self, params: &PreviewParams) -> Result<String> {
        if !params.order.is_empty() {
            let meta = self.column_meta(&params.schema, &params.table)?;
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
            .column_meta(&params.schema, &params.table)?
            .into_iter()
            .filter(|column| column.primary)
            .map(|column| quote_ident(&column.name))
            .collect::<Vec<_>>();
        Ok(primary.join(", "))
    }
}

impl DbSession for PostgresSession {
    fn backend_info(&mut self) -> Result<BackendInfo> {
        let version = self
            .scalar("select version()")?
            .unwrap_or_else(|| "PostgreSQL".to_string());
        let pid = self
            .scalar("select pg_backend_pid()")?
            .and_then(|value| value.parse::<i64>().ok());
        let database = match self.database.clone() {
            Some(database) => Some(database),
            None => self.scalar("select current_database()")?,
        };
        self.database = database.clone();
        Ok(BackendInfo {
            adapter: "postgres".to_string(),
            server_version: version,
            database,
            backend_pid: pid,
            access: self.access.as_str().to_string(),
        })
    }

    fn schemas(&mut self) -> Result<Vec<JsonValue>> {
        let output = self.simple(
            r#"
            select n.nspname,
                   pg_catalog.obj_description(n.oid, 'pg_namespace')
            from pg_namespace n
            where n.nspname not in ('information_schema', 'pg_catalog')
              and n.nspname not like 'pg_toast%'
              and n.nspname not like 'pg_temp%'
            order by n.nspname
            "#,
        )?;
        Ok(output
            .rows
            .iter()
            .map(|row| json!({ "name": text(row.first()), "comment": optional(row.get(1)) }))
            .collect())
    }

    fn tables(&mut self, schema: &str) -> Result<Vec<JsonValue>> {
        let sql = format!(
            r#"
            select c.relname,
                   case c.relkind
                     when 'r' then 'BASE TABLE'
                     when 'p' then 'PARTITIONED TABLE'
                     when 'v' then 'VIEW'
                     when 'm' then 'MATERIALIZED VIEW'
                     when 'f' then 'FOREIGN TABLE'
                     else c.relkind::text
                   end,
                   coalesce(c.reltuples, 0)::bigint,
                   pg_catalog.obj_description(c.oid, 'pg_class')
            from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = {} and c.relkind in ('r', 'p', 'v', 'm', 'f')
            order by c.relname
            "#,
            quote_literal(schema)
        );
        let output = self.simple(&sql)?;
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
        let sql = format!(
            r#"
            select a.attname,
                   format_type(a.atttypid, a.atttypmod),
                   not a.attnotnull,
                   case when pk.attnum is not null then 'PRI' else '' end,
                   pg_get_expr(d.adbin, d.adrelid),
                   pg_catalog.col_description(c.oid, a.attnum),
                   a.attnum
            from pg_attribute a
            join pg_class c on c.oid = a.attrelid
            join pg_namespace n on n.oid = c.relnamespace
            left join pg_attrdef d on d.adrelid = c.oid and d.adnum = a.attnum
            left join (
                select i.indrelid, unnest(i.indkey) as attnum
                from pg_index i where i.indisprimary
            ) pk on pk.indrelid = c.oid and pk.attnum = a.attnum
            where n.nspname = {} and c.relname = {}
              and a.attnum > 0 and not a.attisdropped
            order by a.attnum
            "#,
            quote_literal(schema),
            quote_literal(table)
        );
        let output = self.simple(&sql)?;
        Ok(output
            .rows
            .iter()
            .map(|row| {
                let type_name = text(row.get(1));
                json!({
                    "name": text(row.first()),
                    "type": type_name,
                    "class": classify(&type_name).as_str(),
                    "nullable": text(row.get(2)) == "t",
                    "key": text(row.get(3)),
                    "default": optional(row.get(4)),
                    "comment": optional(row.get(5)),
                    "position": text(row.get(6)).parse::<i64>().unwrap_or(0),
                })
            })
            .collect())
    }

    fn routines(&mut self, schema: &str) -> Result<Vec<JsonValue>> {
        let sql = format!(
            r#"
            select p.proname,
                   case p.prokind when 'f' then 'FUNCTION'
                                  when 'p' then 'PROCEDURE'
                                  when 'a' then 'AGGREGATE'
                                  when 'w' then 'WINDOW'
                                  else 'ROUTINE' end,
                   pg_get_function_result(p.oid),
                   pg_get_function_arguments(p.oid),
                   pg_catalog.obj_description(p.oid, 'pg_proc')
            from pg_proc p
            join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = {}
            order by p.proname
            "#,
            quote_literal(schema)
        );
        let output = self.simple(&sql)?;
        Ok(output
            .rows
            .iter()
            .map(|row| {
                json!({
                    "name": text(row.first()),
                    "kind": text(row.get(1)),
                    "returns": optional(row.get(2)),
                    "arguments": optional(row.get(3)),
                    "comment": optional(row.get(4)),
                })
            })
            .collect())
    }

    fn indexes(&mut self, schema: &str, table: &str) -> Result<Vec<JsonValue>> {
        let sql = format!(
            r#"
            select i.relname,
                   ix.indisunique,
                   ix.indisprimary,
                   pg_get_indexdef(ix.indexrelid),
                   pg_relation_size(i.oid)
            from pg_index ix
            join pg_class i on i.oid = ix.indexrelid
            join pg_class t on t.oid = ix.indrelid
            join pg_namespace n on n.oid = t.relnamespace
            where n.nspname = {} and t.relname = {}
            order by i.relname
            "#,
            quote_literal(schema),
            quote_literal(table)
        );
        let output = self.simple(&sql)?;
        Ok(output
            .rows
            .iter()
            .map(|row| {
                json!({
                    "name": text(row.first()),
                    "unique": text(row.get(1)) == "t",
                    "primary": text(row.get(2)) == "t",
                    "definition": text(row.get(3)),
                    "size_bytes": text(row.get(4)).parse::<i64>().unwrap_or(0),
                })
            })
            .collect())
    }

    fn foreign_keys(&mut self, schema: &str, table: &str) -> Result<Vec<JsonValue>> {
        let sql = format!(
            r#"
            select con.conname,
                   src_col.attname,
                   tgt_ns.nspname,
                   tgt.relname,
                   tgt_col.attname
            from pg_constraint con
            join pg_class src on src.oid = con.conrelid
            join pg_namespace src_ns on src_ns.oid = src.relnamespace
            join pg_class tgt on tgt.oid = con.confrelid
            join pg_namespace tgt_ns on tgt_ns.oid = tgt.relnamespace
            join lateral unnest(con.conkey, con.confkey) as cols(src_attnum, tgt_attnum) on true
            join pg_attribute src_col
              on src_col.attrelid = src.oid and src_col.attnum = cols.src_attnum
            join pg_attribute tgt_col
              on tgt_col.attrelid = tgt.oid and tgt_col.attnum = cols.tgt_attnum
            where con.contype = 'f' and src_ns.nspname = {} and src.relname = {}
            order by con.conname
            "#,
            quote_literal(schema),
            quote_literal(table)
        );
        let output = self.simple(&sql)?;
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
        let sql = format!(
            r#"
            select con.conname,
                   src_ns.nspname,
                   src.relname,
                   src_col.attname,
                   tgt_col.attname
            from pg_constraint con
            join pg_class src on src.oid = con.conrelid
            join pg_namespace src_ns on src_ns.oid = src.relnamespace
            join pg_class tgt on tgt.oid = con.confrelid
            join pg_namespace tgt_ns on tgt_ns.oid = tgt.relnamespace
            join lateral unnest(con.conkey, con.confkey) as cols(src_attnum, tgt_attnum) on true
            join pg_attribute src_col
              on src_col.attrelid = src.oid and src_col.attnum = cols.src_attnum
            join pg_attribute tgt_col
              on tgt_col.attrelid = tgt.oid and tgt_col.attnum = cols.tgt_attnum
            where con.contype = 'f' and tgt_ns.nspname = {} and tgt.relname = {}
            order by src.relname, con.conname
            "#,
            quote_literal(schema),
            quote_literal(table)
        );
        let output = self.simple(&sql)?;
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
        let sql = format!(
            r#"
            select src.relname, src_col.attname, con.conname,
                   tgt_ns.nspname, tgt.relname, tgt_col.attname
            from pg_constraint con
            join pg_class src on src.oid = con.conrelid
            join pg_namespace src_ns on src_ns.oid = src.relnamespace
            join pg_class tgt on tgt.oid = con.confrelid
            join pg_namespace tgt_ns on tgt_ns.oid = tgt.relnamespace
            join lateral unnest(con.conkey, con.confkey) as cols(src_attnum, tgt_attnum) on true
            join pg_attribute src_col
              on src_col.attrelid = src.oid and src_col.attnum = cols.src_attnum
            join pg_attribute tgt_col
              on tgt_col.attrelid = tgt.oid and tgt_col.attnum = cols.tgt_attnum
            where con.contype = 'f' and src_ns.nspname = {}
            order by src.relname, con.conname
            "#,
            quote_literal(schema)
        );
        let output = self.simple(&sql)?;
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
        let mut output = self.simple(&sql)?;
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
        let mut output = self.simple(sql)?;
        if output.rows.len() as u64 > cap {
            output.truncated = true;
            output.rows.truncate(cap as usize);
        }
        Ok(output)
    }

    fn validate(&mut self, sql: &str) -> Result<Option<ValidationError>> {
        // `prepare` describes without executing, and the returned statement
        // deallocates when it drops.
        match self.client.prepare(sql) {
            Ok(_) => Ok(None),
            Err(error) => {
                let db_error = error.as_db_error();
                let position = db_error.and_then(|error| match error.position() {
                    Some(postgres::error::ErrorPosition::Original(position)) => Some(*position),
                    Some(postgres::error::ErrorPosition::Internal { position, .. }) => {
                        Some(*position)
                    }
                    None => None,
                });
                let message = db_error
                    .map(|error| error.message().to_string())
                    .unwrap_or_else(|| error.to_string());
                Ok(Some(ValidationError { message, position }))
            }
        }
    }

    fn stream_query(&mut self, sql: &str, batch_size: usize, sink: BatchSink<'_>) -> Result<u64> {
        self.enforce_access(sql)?;

        // A cursor is what keeps memory flat: without one the server sends the
        // whole result and the client buffers it, which is exactly what export
        // exists to avoid.
        let columns = self.describe(sql).unwrap_or_default();
        let opened_transaction = !self.in_transaction;
        if opened_transaction {
            self.client.batch_execute("begin")?;
        }

        let result = (|| -> Result<u64> {
            self.client
                .batch_execute(&format!(
                    "declare dbclient_export no scroll cursor for {sql}"
                ))
                .context("failed to open an export cursor")?;

            let mut total = 0u64;
            let mut described = columns.clone();

            loop {
                let output =
                    self.simple(&format!("fetch forward {batch_size} from dbclient_export"))?;
                if described.is_empty() {
                    described = output.columns.clone();
                }
                let count = output.rows.len() as u64;
                total += count;

                let last = count < batch_size as u64;
                if !sink(&described, output.rows)? {
                    break;
                }
                if last {
                    break;
                }
            }

            Ok(total)
        })();

        let _ = self.client.batch_execute("close dbclient_export");
        if opened_transaction {
            let _ = self.client.batch_execute("commit");
        }

        result
    }

    fn explain(&mut self, sql: &str, analyze: bool) -> Result<JsonValue> {
        if analyze {
            self.enforce_access(sql)?;
        }
        let options = if analyze {
            "(analyze, buffers, verbose, costs, format json)"
        } else {
            "(verbose, costs, format json)"
        };
        // ANALYZE actually runs the statement, so keep it inside a transaction
        // that we roll back unless the caller is already in one.
        let wrap = analyze && !self.in_transaction;
        if wrap {
            self.client.batch_execute("begin")?;
        }
        let result = self.simple(&format!("explain {options} {sql}"));
        if wrap {
            let _ = self.client.batch_execute("rollback");
        }
        let output = result?;
        let raw = output
            .rows
            .first()
            .and_then(|row| row.first())
            .and_then(|value| value.as_str())
            .unwrap_or("[]");
        let plan: JsonValue = serde_json::from_str(raw).unwrap_or(json!([]));
        Ok(json!({ "format": "postgres-json", "plan": plan }))
    }

    fn apply_changes(&mut self, changes: &[RowChange]) -> Result<ApplyOutcome> {
        if self.access == Access::Read {
            return Err(anyhow!("connection is read-only"));
        }

        let already_open = self.in_transaction;
        if !already_open {
            self.client.batch_execute("begin")?;
        }

        let mut statements = Vec::new();
        let mut affected = 0u64;
        let sandbox = self.access == Access::Sandbox;

        let outcome = (|| -> Result<()> {
            for change in changes {
                let (sql, values) = self.render_change(change)?;
                let params = values
                    .iter()
                    .map(|value| value as &(dyn ToSql + Sync))
                    .collect::<Vec<_>>();
                let count = self
                    .client
                    .execute(sql.as_str(), &params)
                    .with_context(|| format!("failed to apply {}", change.label()))?;
                if count == 0 {
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
                self.client.batch_execute("rollback")?;
                self.in_transaction = false;
                statements.push("-- sandbox: rolled back".to_string());
            }
            Ok(()) if !already_open => {
                self.client.batch_execute("commit")?;
                self.in_transaction = false;
            }
            Ok(()) => {}
            Err(error) => {
                let _ = self.client.batch_execute("rollback");
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
            let literals = values
                .iter()
                .map(|value| match value {
                    Some(text) => quote_literal(text),
                    None => "null".to_string(),
                })
                .collect::<Vec<_>>();
            statements.push(format!("{};", inline_placeholders(&sql, &literals, '$')));
        }
        Ok(statements)
    }

    fn begin(&mut self) -> Result<()> {
        if self.in_transaction {
            return Err(anyhow!("a transaction is already open"));
        }
        self.client.batch_execute("begin")?;
        self.in_transaction = true;
        Ok(())
    }

    fn commit(&mut self) -> Result<()> {
        if !self.in_transaction {
            return Err(anyhow!("no open transaction"));
        }
        self.client.batch_execute("commit")?;
        self.in_transaction = false;
        Ok(())
    }

    fn rollback(&mut self) -> Result<()> {
        if !self.in_transaction {
            return Err(anyhow!("no open transaction"));
        }
        self.client.batch_execute("rollback")?;
        self.in_transaction = false;
        Ok(())
    }

    fn in_transaction(&self) -> bool {
        self.in_transaction
    }

    fn ddl(&mut self, kind: DdlKind, schema: &str, name: &str) -> Result<String> {
        match kind {
            DdlKind::View => {
                let sql = format!(
                    "select pg_get_viewdef({}::regclass, true)",
                    quote_literal(&format!("{}.{}", quote_ident(schema), quote_ident(name)))
                );
                let body = self.scalar(&sql)?.unwrap_or_default();
                Ok(format!(
                    "create or replace view {}.{} as\n{}",
                    quote_ident(schema),
                    quote_ident(name),
                    body.trim()
                ))
            }
            DdlKind::Routine => {
                let sql = format!(
                    r#"
                    select string_agg(pg_get_functiondef(p.oid), E';\n\n')
                    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = {} and p.proname = {}
                    "#,
                    quote_literal(schema),
                    quote_literal(name)
                );
                self.scalar(&sql)?
                    .ok_or_else(|| anyhow!("routine {schema}.{name} not found"))
            }
            DdlKind::Index => {
                let sql = format!(
                    r#"
                    select pg_get_indexdef(i.oid)
                    from pg_class i join pg_namespace n on n.oid = i.relnamespace
                    where n.nspname = {} and i.relname = {}
                    "#,
                    quote_literal(schema),
                    quote_literal(name)
                );
                self.scalar(&sql)?
                    .ok_or_else(|| anyhow!("index {schema}.{name} not found"))
            }
            DdlKind::Trigger => {
                let sql = format!(
                    r#"
                    select string_agg(pg_get_triggerdef(t.oid), E';\n')
                    from pg_trigger t
                    join pg_class c on c.oid = t.tgrelid
                    join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = {} and c.relname = {} and not t.tgisinternal
                    "#,
                    quote_literal(schema),
                    quote_literal(name)
                );
                Ok(self.scalar(&sql)?.unwrap_or_default())
            }
            DdlKind::Table => self.table_ddl(schema, name),
        }
    }

    fn column_stats(&mut self, schema: &str, table: &str, column: &str) -> Result<JsonValue> {
        let meta = self.meta_for(schema, table, column)?;
        let qualified = format!("{}.{}", quote_ident(schema), quote_ident(table));
        let quoted = quote_ident(column);
        let class = classify(&meta.type_name);

        let base = format!(
            r#"
            select count(*)::text,
                   count({quoted})::text,
                   count(distinct {quoted})::text
            from {qualified}
            "#
        );
        let summary = self.simple(&base)?;
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
            let sql = format!("select min({quoted})::text, max({quoted})::text from {qualified}");
            if let Ok(range) = self.simple(&sql) {
                if let Some(values) = range.rows.first() {
                    stats["min"] = json!(text(values.first()));
                    stats["max"] = json!(text(values.get(1)));
                }
            }
            if class == ValueClass::Number {
                let sql = format!(
                    "select avg({quoted})::text, stddev_pop({quoted})::text from {qualified}"
                );
                if let Ok(agg) = self.simple(&sql) {
                    if let Some(values) = agg.rows.first() {
                        stats["avg"] = json!(text(values.first()));
                        stats["stddev"] = json!(text(values.get(1)));
                    }
                }
            }
        }

        let top_sql = format!(
            r#"
            select {quoted}::text, count(*)::text
            from {qualified}
            group by 1 order by count(*) desc, 1
            limit 10
            "#
        );
        let top = self.simple(&top_sql)?;
        stats["top"] = JsonValue::Array(
            top.rows
                .iter()
                .map(|row| json!({ "value": optional(row.first()), "count": text(row.get(1)) }))
                .collect(),
        );

        Ok(stats)
    }

    fn activity(&mut self) -> Result<QueryOutput> {
        self.simple(
            r#"
            select pid::text as pid,
                   coalesce(usename, '') as "user",
                   coalesce(datname, '') as database,
                   coalesce(application_name, '') as application,
                   coalesce(client_addr::text, 'local') as client,
                   state,
                   coalesce(wait_event_type || ':' || wait_event, '') as wait,
                   to_char(now() - query_start, 'HH24:MI:SS') as runtime,
                   left(regexp_replace(query, '\s+', ' ', 'g'), 200) as query
            from pg_stat_activity
            where pid <> pg_backend_pid() and state is not null
            order by query_start nulls last
            "#,
        )
    }

    fn locks(&mut self) -> Result<QueryOutput> {
        self.simple(
            r#"
            select blocked.pid::text as blocked_pid,
                   coalesce(blocked.usename, '') as blocked_user,
                   blocking.pid::text as blocking_pid,
                   coalesce(blocking.usename, '') as blocking_user,
                   to_char(now() - blocked.query_start, 'HH24:MI:SS') as blocked_for,
                   left(regexp_replace(blocked.query, '\s+', ' ', 'g'), 120) as blocked_query,
                   left(regexp_replace(blocking.query, '\s+', ' ', 'g'), 120) as blocking_query
            from pg_stat_activity blocked
            join lateral unnest(pg_blocking_pids(blocked.pid)) as blocker(pid) on true
            join pg_stat_activity blocking on blocking.pid = blocker.pid
            order by blocked.query_start
            "#,
        )
    }

    fn table_sizes(&mut self, schema: &str) -> Result<QueryOutput> {
        let sql = format!(
            r#"
            select c.relname as table,
                   pg_size_pretty(pg_total_relation_size(c.oid)) as total,
                   pg_size_pretty(pg_relation_size(c.oid)) as heap,
                   pg_size_pretty(pg_indexes_size(c.oid)) as indexes,
                   c.reltuples::bigint::text as est_rows,
                   pg_total_relation_size(c.oid)::text as total_bytes
            from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = {} and c.relkind in ('r', 'p', 'm')
            order by pg_total_relation_size(c.oid) desc
            "#,
            quote_literal(schema)
        );
        self.simple(&sql)
    }

    fn unused_indexes(&mut self, schema: &str) -> Result<QueryOutput> {
        let sql = format!(
            r#"
            select s.relname as table,
                   s.indexrelname as index,
                   s.idx_scan::text as scans,
                   pg_size_pretty(pg_relation_size(s.indexrelid)) as size,
                   case when ix.indisunique then 'unique' else '' end as flags
            from pg_stat_user_indexes s
            join pg_index ix on ix.indexrelid = s.indexrelid
            where s.schemaname = {} and not ix.indisprimary
            order by s.idx_scan, pg_relation_size(s.indexrelid) desc
            "#,
            quote_literal(schema)
        );
        self.simple(&sql)
    }

    fn cancel_handle(&mut self) -> CancelHandle {
        CancelHandle::Postgres(Box::new(self.client.cancel_token()))
    }

    fn dialect(&self) -> &'static str {
        "postgres"
    }

    fn access(&self) -> Access {
        self.access
    }
}

impl PostgresSession {
    /// Render one staged change into parameterised SQL.
    fn render_change(&mut self, change: &RowChange) -> Result<(String, Vec<Option<String>>)> {
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
                let mut values = Vec::new();
                let mut assignments = Vec::new();
                for (column, value) in set {
                    let meta = self.meta_for(schema, table, column)?;
                    values.push(coerce(value, &meta)?);
                    assignments.push(format!(
                        "{} = ${}::text::{}",
                        quote_ident(column),
                        values.len(),
                        meta.type_name
                    ));
                }
                let filters = self.where_clause(schema, table, pk, expect, &mut values)?;
                Ok((
                    format!(
                        "update {}.{} set {} where {}",
                        quote_ident(schema),
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
                let mut values = Vec::new();
                let mut columns = Vec::new();
                let mut placeholders = Vec::new();
                for (column, value) in fields {
                    let meta = self.meta_for(schema, table, column)?;
                    values.push(coerce(value, &meta)?);
                    columns.push(quote_ident(column));
                    placeholders.push(format!("${}::text::{}", values.len(), meta.type_name));
                }
                Ok((
                    format!(
                        "insert into {}.{} ({}) values ({})",
                        quote_ident(schema),
                        quote_ident(table),
                        columns.join(", "),
                        placeholders.join(", ")
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
                let mut values = Vec::new();
                let filters = self.where_clause(schema, table, pk, expect, &mut values)?;
                Ok((
                    format!(
                        "delete from {}.{} where {}",
                        quote_ident(schema),
                        quote_ident(table),
                        filters
                    ),
                    values,
                ))
            }
        }
    }

    /// Primary key predicate plus optimistic concurrency checks on the values
    /// the snapshot was taken from.
    fn where_clause(
        &mut self,
        schema: &str,
        table: &str,
        pk: &BTreeMap<String, JsonValue>,
        expect: &BTreeMap<String, JsonValue>,
        values: &mut Vec<Option<String>>,
    ) -> Result<String> {
        let mut filters = Vec::new();
        for (column, value) in pk
            .iter()
            .chain(expect.iter().filter(|(key, _)| !pk.contains_key(*key)))
        {
            let meta = self.meta_for(schema, table, column)?;
            values.push(coerce(value, &meta)?);
            filters.push(format!(
                "{} is not distinct from ${}::text::{}",
                quote_ident(column),
                values.len(),
                meta.type_name
            ));
        }
        Ok(filters.join(" and "))
    }

    /// Reconstruct `create table` from the catalog. PostgreSQL has no
    /// `show create table`, so this assembles columns, keys, checks and
    /// indexes into something that round-trips through the schema diff.
    fn table_ddl(&mut self, schema: &str, table: &str) -> Result<String> {
        let columns = self.columns(schema, table)?;
        if columns.is_empty() {
            return Err(anyhow!("unknown table {schema}.{table}"));
        }

        let mut lines = Vec::new();
        for column in &columns {
            let name = column["name"].as_str().unwrap_or_default();
            let type_name = column["type"].as_str().unwrap_or_default();
            let mut line = format!("  {} {}", quote_ident(name), type_name);
            if let Some(default) = column["default"].as_str() {
                line.push_str(&format!(" default {default}"));
            }
            if !column["nullable"].as_bool().unwrap_or(true) {
                line.push_str(" not null");
            }
            lines.push(line);
        }

        let constraint_sql = format!(
            r#"
            select con.conname, pg_get_constraintdef(con.oid)
            from pg_constraint con
            join pg_class c on c.oid = con.conrelid
            join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = {} and c.relname = {}
            order by case con.contype when 'p' then 0 when 'u' then 1
                                      when 'f' then 2 else 3 end, con.conname
            "#,
            quote_literal(schema),
            quote_literal(table)
        );
        for row in self.simple(&constraint_sql)?.rows {
            lines.push(format!(
                "  constraint {} {}",
                quote_ident(&text(row.first())),
                text(row.get(1))
            ));
        }

        let mut ddl = format!(
            "create table {}.{} (\n{}\n);",
            quote_ident(schema),
            quote_ident(table),
            lines.join(",\n")
        );

        for index in self.indexes(schema, table)? {
            if index["primary"].as_bool().unwrap_or(false) {
                continue;
            }
            if let Some(definition) = index["definition"].as_str() {
                ddl.push_str(&format!("\n\n{definition};"));
            }
        }

        for column in &columns {
            if let Some(comment) = column["comment"].as_str() {
                ddl.push_str(&format!(
                    "\n\ncomment on column {}.{}.{} is {};",
                    quote_ident(schema),
                    quote_ident(table),
                    quote_ident(column["name"].as_str().unwrap_or_default()),
                    quote_literal(comment)
                ));
            }
        }

        Ok(ddl)
    }
}

/// Values travel as text and are cast server-side with `$n::text::<type>`.
///
/// Casting directly to the column type instead would make PostgreSQL infer the
/// *parameter* as that type, and the driver would then refuse to send a string
/// for an `int8`. Going through `text` keeps one representation on the wire and
/// lets the server do every conversion, including for arrays, enums and JSON.
fn coerce(value: &JsonValue, meta: &ColumnMeta) -> Result<Option<String>> {
    if value.is_null() {
        if meta.nullable {
            return Ok(None);
        }
        return Err(anyhow!("column {} does not allow NULL", meta.name));
    }
    let text = match value {
        JsonValue::String(value) => value.clone(),
        JsonValue::Number(value) => value.to_string(),
        JsonValue::Bool(value) => value.to_string(),
        _ => return Err(anyhow!("cell value must be scalar")),
    };
    Ok(Some(text))
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

fn escape_param(value: &str) -> String {
    if value.contains(' ') || value.contains('\'') || value.contains('\\') {
        format!("'{}'", value.replace('\\', "\\\\").replace('\'', "\\'"))
    } else {
        value.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_identifiers() {
        assert_eq!(quote_ident("users"), "\"users\"");
        assert_eq!(quote_ident("we\"ird"), "\"we\"\"ird\"");
    }

    #[test]
    fn quotes_literals() {
        assert_eq!(quote_literal("it's"), "'it''s'");
    }

    #[test]
    fn escapes_connection_params() {
        assert_eq!(escape_param("simple"), "simple");
        assert_eq!(escape_param("with space"), "'with space'");
        assert_eq!(escape_param("qu'ote"), "'qu\\'ote'");
    }
}
