use crate::adapter::{CellUpdate, Connection, DbAdapter, QueryOutput};
use anyhow::{anyhow, Context, Result};
use rusqlite::types::{Value, ValueRef};
use rusqlite::{params_from_iter, Connection as SqliteConnection};
use serde_json::{json, Value as JsonValue};

pub struct SqliteAdapter;

impl DbAdapter for SqliteAdapter {
    fn schemas(&self, connection: &Connection) -> Result<Vec<String>> {
        let conn = sqlite_connection(connection)?;
        let mut statement = conn.prepare("pragma database_list")?;
        let rows = statement.query_map([], |row| row.get::<_, String>(1))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .context("failed to list SQLite databases")
    }

    fn tables(&self, connection: &Connection, schema: &str) -> Result<Vec<JsonValue>> {
        let conn = sqlite_connection(connection)?;
        let sql = format!(
            "select name, type from {}.sqlite_master where type in ('table', 'view') and name not like 'sqlite_%' order by name",
            quote_identifier(schema)
        );
        let mut statement = conn.prepare(&sql)?;
        let rows = statement.query_map([], |row| {
            Ok(json!({
                "name": row.get::<_, String>(0)?,
                "kind": row.get::<_, String>(1)?.to_uppercase(),
            }))
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .context("failed to list SQLite tables")
    }

    fn columns(
        &self,
        connection: &Connection,
        schema: &str,
        table: &str,
    ) -> Result<Vec<JsonValue>> {
        let conn = sqlite_connection(connection)?;
        table_info(&conn, schema, table)
    }

    fn routines(&self, _connection: &Connection, _schema: &str) -> Result<Vec<JsonValue>> {
        Ok(Vec::new())
    }

    fn preview(
        &self,
        connection: &Connection,
        schema: &str,
        table: &str,
        limit: u64,
    ) -> Result<QueryOutput> {
        let conn = sqlite_connection(connection)?;
        let sql = format!(
            "select * from {}.{} limit {}",
            quote_identifier(schema),
            quote_identifier(table),
            limit.clamp(1, 10_000)
        );
        collect_query(&conn, &sql, Vec::new())
    }

    fn update_cell(&self, connection: &Connection, update: CellUpdate<'_>) -> Result<JsonValue> {
        let conn = sqlite_connection(connection)?;
        let changed = apply_cell_update(&conn, update)?;
        Ok(json!({ "affected_rows": changed }))
    }

    fn update_cells(
        &self,
        connection: &Connection,
        updates: &[CellUpdate<'_>],
    ) -> Result<JsonValue> {
        let mut conn = sqlite_connection(connection)?;
        let transaction = conn.transaction()?;
        let mut changed = 0;

        for update in updates {
            changed += apply_cell_update(&transaction, *update)?;
        }

        transaction.commit()?;
        Ok(json!({ "affected_rows": changed }))
    }

    fn query(&self, connection: &Connection, sql: &str) -> Result<QueryOutput> {
        let conn = sqlite_connection(connection)?;
        collect_query(&conn, sql, Vec::new())
    }
}

#[derive(Clone)]
struct ColumnMeta {
    data_type: String,
    nullable: bool,
}

fn sqlite_connection(connection: &Connection) -> Result<SqliteConnection> {
    let path = connection
        .path
        .as_ref()
        .or(connection.database.as_ref())
        .context("SQLite connection requires path")?;
    SqliteConnection::open(path).context("failed to open SQLite database")
}

fn table_info(conn: &SqliteConnection, schema: &str, table: &str) -> Result<Vec<JsonValue>> {
    let sql = format!(
        "pragma {}.table_info({})",
        quote_identifier(schema),
        quote_string(table)
    );
    let mut statement = conn.prepare(&sql)?;
    let rows = statement.query_map([], |row| {
        let nullable = row.get::<_, i64>(3)? == 0;
        let pk = row.get::<_, i64>(5)? > 0;
        Ok(json!({
            "name": row.get::<_, String>(1)?,
            "type": row.get::<_, String>(2)?,
            "nullable": nullable,
            "key": if pk { "PRI" } else { "" },
        }))
    })?;
    rows.collect::<rusqlite::Result<Vec<_>>>()
        .context("failed to list SQLite columns")
}

fn column_meta(
    conn: &SqliteConnection,
    schema: &str,
    table: &str,
    column: &str,
) -> Result<ColumnMeta> {
    table_info(conn, schema, table)?
        .into_iter()
        .find(|item| item["name"] == column)
        .map(|item| ColumnMeta {
            data_type: item["type"].as_str().unwrap_or_default().to_string(),
            nullable: item["nullable"].as_bool().unwrap_or(true),
        })
        .ok_or_else(|| anyhow!("unknown column {schema}.{table}.{column}"))
}

fn apply_cell_update(conn: &SqliteConnection, update: CellUpdate<'_>) -> Result<usize> {
    if update.pk.is_empty() {
        return Err(anyhow!("cell update requires a primary key"));
    }

    let target = column_meta(conn, update.schema, update.table, update.column)?;
    let mut values = vec![validated_value(update.value, &target)?];
    let mut filters = Vec::new();

    for (column, value) in update.pk {
        let meta = column_meta(conn, update.schema, update.table, column)?;
        values.push(validated_value(value, &meta)?);
        filters.push(format!("{} is ?", quote_identifier(column)));
    }

    let sql = format!(
        "update {}.{} set {} = ? where {}",
        quote_identifier(update.schema),
        quote_identifier(update.table),
        quote_identifier(update.column),
        filters.join(" and ")
    );
    conn.execute(&sql, params_from_iter(values.iter()))
        .context("failed to update SQLite cell")
}

fn collect_query(conn: &SqliteConnection, sql: &str, values: Vec<Value>) -> Result<QueryOutput> {
    let mut statement = conn
        .prepare(sql)
        .context("failed to prepare SQLite query")?;
    let columns = statement
        .column_names()
        .into_iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>();

    if columns.is_empty() {
        let changed = statement
            .execute(params_from_iter(values.iter()))
            .context("failed to execute SQLite statement")?;
        return Ok(QueryOutput {
            columns,
            rows: Vec::new(),
            affected_rows: changed as u64,
        });
    }

    let column_count = columns.len();
    let rows = statement.query_map(params_from_iter(values.iter()), |row| {
        let mut values = Vec::new();
        for index in 0..column_count {
            values.push(value_to_json(row.get_ref(index)?));
        }
        Ok(values)
    })?;
    let rows = rows.collect::<rusqlite::Result<Vec<_>>>()?;

    Ok(QueryOutput {
        columns,
        rows,
        affected_rows: 0,
    })
}

fn validated_value(value: &JsonValue, meta: &ColumnMeta) -> Result<Value> {
    if value.is_null() {
        if meta.nullable {
            return Ok(Value::Null);
        }
        return Err(anyhow!("column does not allow NULL"));
    }

    let text = match value {
        JsonValue::String(value) => value.clone(),
        JsonValue::Number(value) => value.to_string(),
        JsonValue::Bool(value) => value.to_string(),
        _ => return Err(anyhow!("cell value must be scalar")),
    };

    let affinity = meta.data_type.to_ascii_uppercase();
    if affinity.contains("INT") {
        return text
            .parse::<i64>()
            .map(Value::Integer)
            .context("expected integer value");
    }
    if affinity.contains("REAL") || affinity.contains("FLOA") || affinity.contains("DOUB") {
        return text
            .parse::<f64>()
            .map(Value::Real)
            .context("expected real value");
    }

    Ok(Value::Text(text))
}

fn value_to_json(value: ValueRef<'_>) -> JsonValue {
    match value {
        ValueRef::Null => JsonValue::Null,
        ValueRef::Integer(value) => json!(value),
        ValueRef::Real(value) => json!(value),
        ValueRef::Text(value) => String::from_utf8(value.to_vec())
            .map(JsonValue::String)
            .unwrap_or_else(|_| json!(value)),
        ValueRef::Blob(value) => json!(value),
    }
}

fn quote_identifier(identifier: &str) -> String {
    format!("\"{}\"", identifier.replace('"', "\"\""))
}

fn quote_string(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}
