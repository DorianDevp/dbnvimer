use crate::adapter::{CellUpdate, Connection, DbAdapter, QueryOutput};
use anyhow::{anyhow, Context, Result};
use mysql::prelude::Queryable;
use mysql::{OptsBuilder, Params, Pool, Row, Value};
use serde_json::{json, Value as JsonValue};

pub struct MariaDbAdapter;

impl DbAdapter for MariaDbAdapter {
    fn schemas(&self, connection: &Connection) -> Result<Vec<String>> {
        let mut conn = mysql_connection(connection)?;
        conn.query_map(
            "select schema_name from information_schema.schemata order by schema_name",
            |schema: String| schema,
        )
        .context("failed to list schemas")
    }

    fn tables(&self, connection: &Connection, schema: &str) -> Result<Vec<JsonValue>> {
        let mut conn = mysql_connection(connection)?;
        conn.exec_map(
            r#"
            select table_name, table_type
            from information_schema.tables
            where table_schema = ?
            order by table_name
            "#,
            (schema,),
            |(name, kind): (String, String)| json!({ "name": name, "kind": kind }),
        )
        .context("failed to list tables")
    }

    fn columns(
        &self,
        connection: &Connection,
        schema: &str,
        table: &str,
    ) -> Result<Vec<JsonValue>> {
        let mut conn = mysql_connection(connection)?;
        conn.exec_map(
            r#"
            select column_name, column_type, is_nullable, column_key
            from information_schema.columns
            where table_schema = ? and table_name = ?
            order by ordinal_position
            "#,
            (schema, table),
            |(name, data_type, nullable, key): (String, String, String, String)| {
                json!({
                    "name": name,
                    "type": data_type,
                    "nullable": nullable == "YES",
                    "key": key,
                })
            },
        )
        .context("failed to list columns")
    }

    fn routines(&self, connection: &Connection, schema: &str) -> Result<Vec<JsonValue>> {
        let mut conn = mysql_connection(connection)?;
        conn.exec_map(
            r#"
            select routine_name, routine_type, dtd_identifier, routine_comment
            from information_schema.routines
            where routine_schema = ?
            order by routine_type, routine_name
            "#,
            (schema,),
            |(name, kind, returns, comment): (String, String, Option<String>, Option<String>)| {
                json!({
                    "name": name,
                    "kind": kind,
                    "returns": returns,
                    "comment": comment,
                })
            },
        )
        .context("failed to list routines")
    }

    fn preview(
        &self,
        connection: &Connection,
        schema: &str,
        table: &str,
        limit: u64,
    ) -> Result<QueryOutput> {
        let mut conn = mysql_connection(connection)?;
        let limit = limit.clamp(1, 10_000);
        let sql = format!(
            "select * from {}.{} limit {}",
            quote_identifier(schema),
            quote_identifier(table),
            limit
        );
        collect_query(&mut conn, &sql, Params::Empty)
    }

    fn update_cell(&self, connection: &Connection, update: CellUpdate<'_>) -> Result<JsonValue> {
        if update.pk.is_empty() {
            return Err(anyhow!("cell update requires a primary key"));
        }

        let mut conn = mysql_connection(connection)?;
        let target = column_meta(&mut conn, update.schema, update.table, update.column)?;
        let mut params = vec![validated_value(update.value, &target)?];
        let mut filters = Vec::new();

        for (pk_column, pk_value) in update.pk {
            let meta = column_meta(&mut conn, update.schema, update.table, pk_column)?;
            params.push(validated_value(pk_value, &meta)?);
            filters.push(format!("{} <=> ?", quote_identifier(pk_column)));
        }

        let sql = format!(
            "update {}.{} set {} = ? where {} limit 1",
            quote_identifier(update.schema),
            quote_identifier(update.table),
            quote_identifier(update.column),
            filters.join(" and ")
        );
        conn.exec_drop(sql, Params::Positional(params))
            .context("failed to update cell")?;

        Ok(json!({ "affected_rows": conn.affected_rows() }))
    }

    fn query(&self, connection: &Connection, sql: &str) -> Result<QueryOutput> {
        let mut conn = mysql_connection(connection)?;
        collect_query(&mut conn, sql, Params::Empty)
    }
}

fn mysql_connection(connection: &Connection) -> Result<mysql::PooledConn> {
    let mut builder = OptsBuilder::new()
        .ip_or_hostname(Some(connection.host.clone()))
        .tcp_port(connection.port)
        .user(Some(connection.user.clone()));

    if let Some(password) = &connection.password {
        builder = builder.pass(Some(password.clone()));
    }

    if let Some(database) = &connection.database {
        builder = builder.db_name(Some(database.clone()));
    }

    Pool::new(builder)
        .context("failed to create MariaDB pool")?
        .get_conn()
        .context("failed to connect to MariaDB")
}

fn collect_query(conn: &mut mysql::PooledConn, sql: &str, params: Params) -> Result<QueryOutput> {
    let mut result = conn
        .exec_iter(sql, params)
        .context("failed to execute query")?;
    let columns = result
        .columns()
        .as_ref()
        .iter()
        .map(|column| column.name_str().into_owned())
        .collect::<Vec<_>>();

    let mut rows = Vec::new();
    for row in result.by_ref() {
        rows.push(row_to_json(row?, columns.len()));
    }

    Ok(QueryOutput {
        columns,
        rows,
        affected_rows: result.affected_rows(),
    })
}

struct ColumnMeta {
    data_type: String,
    nullable: bool,
}

fn column_meta(
    conn: &mut mysql::PooledConn,
    schema: &str,
    table: &str,
    column: &str,
) -> Result<ColumnMeta> {
    conn.exec_first(
        r#"
        select data_type, is_nullable
        from information_schema.columns
        where table_schema = ? and table_name = ? and column_name = ?
        "#,
        (schema, table, column),
    )
    .context("failed to read column metadata")?
    .map(|(data_type, nullable): (String, String)| ColumnMeta {
        data_type,
        nullable: nullable == "YES",
    })
    .ok_or_else(|| anyhow!("unknown column {schema}.{table}.{column}"))
}

fn validated_value(value: &JsonValue, meta: &ColumnMeta) -> Result<Value> {
    if value.is_null() {
        if meta.nullable {
            return Ok(Value::NULL);
        }
        return Err(anyhow!("column does not allow NULL"));
    }

    let text = match value {
        JsonValue::String(value) => value.clone(),
        JsonValue::Number(value) => value.to_string(),
        JsonValue::Bool(value) => value.to_string(),
        _ => return Err(anyhow!("cell value must be scalar")),
    };

    if numeric_type(&meta.data_type) && text.parse::<f64>().is_err() {
        return Err(anyhow!("expected numeric value for {}", meta.data_type));
    }

    Ok(Value::Bytes(text.into_bytes()))
}

fn numeric_type(data_type: &str) -> bool {
    matches!(
        data_type,
        "bit"
            | "tinyint"
            | "smallint"
            | "mediumint"
            | "int"
            | "integer"
            | "bigint"
            | "decimal"
            | "dec"
            | "float"
            | "double"
            | "real"
    )
}

fn quote_identifier(identifier: &str) -> String {
    format!("`{}`", identifier.replace('`', "``"))
}

fn row_to_json(row: Row, width: usize) -> Vec<JsonValue> {
    (0..width)
        .map(|index| {
            row.as_ref(index)
                .map(value_to_json)
                .unwrap_or(JsonValue::Null)
        })
        .collect()
}

fn value_to_json(value: &Value) -> JsonValue {
    match value {
        Value::NULL => JsonValue::Null,
        Value::Bytes(bytes) => String::from_utf8(bytes.clone())
            .map(JsonValue::String)
            .unwrap_or_else(|_| json!(bytes)),
        Value::Int(value) => json!(value),
        Value::UInt(value) => json!(value),
        Value::Float(value) => json!(value),
        Value::Double(value) => json!(value),
        Value::Date(year, month, day, hour, minute, second, micros) => {
            json!(format!(
                "{year:04}-{month:02}-{day:02} {hour:02}:{minute:02}:{second:02}.{micros:06}"
            ))
        }
        Value::Time(negative, days, hours, minutes, seconds, micros) => {
            let sign = if *negative { "-" } else { "" };
            json!(format!(
                "{sign}{days} {hours:02}:{minutes:02}:{seconds:02}.{micros:06}"
            ))
        }
    }
}
