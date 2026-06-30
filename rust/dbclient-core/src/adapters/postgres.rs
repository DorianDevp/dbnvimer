use crate::adapter::{CellUpdate, Connection, DbAdapter, QueryOutput};
use anyhow::{anyhow, Context, Result};
use postgres::types::{ToSql, Type};
use postgres::{Client, NoTls, Row};
use serde_json::{json, Value as JsonValue};

pub struct PostgresAdapter;

impl DbAdapter for PostgresAdapter {
    fn schemas(&self, connection: &Connection) -> Result<Vec<String>> {
        let mut client = postgres_connection(connection)?;
        let rows = client.query(
            r#"
            select schema_name
            from information_schema.schemata
            where schema_name not in ('information_schema', 'pg_catalog')
              and schema_name not like 'pg_toast%'
            order by schema_name
            "#,
            &[],
        )?;
        Ok(rows.into_iter().map(|row| row.get(0)).collect())
    }

    fn tables(&self, connection: &Connection, schema: &str) -> Result<Vec<JsonValue>> {
        let mut client = postgres_connection(connection)?;
        let rows = client.query(
            r#"
            select table_name, table_type
            from information_schema.tables
            where table_schema = $1
            order by table_name
            "#,
            &[&schema],
        )?;
        Ok(rows
            .into_iter()
            .map(|row| json!({ "name": row.get::<_, String>(0), "kind": row.get::<_, String>(1) }))
            .collect())
    }

    fn columns(
        &self,
        connection: &Connection,
        schema: &str,
        table: &str,
    ) -> Result<Vec<JsonValue>> {
        let mut client = postgres_connection(connection)?;
        list_columns(&mut client, schema, table)
    }

    fn routines(&self, connection: &Connection, schema: &str) -> Result<Vec<JsonValue>> {
        let mut client = postgres_connection(connection)?;
        let rows = client.query(
            r#"
            select routine_name, routine_type, data_type, coalesce(external_language, '')
            from information_schema.routines
            where specific_schema = $1
            order by routine_type, routine_name
            "#,
            &[&schema],
        )?;
        Ok(rows
            .into_iter()
            .map(|row| {
                json!({
                    "name": row.get::<_, String>(0),
                    "kind": row.get::<_, String>(1),
                    "returns": row.get::<_, String>(2),
                    "comment": row.get::<_, String>(3),
                })
            })
            .collect())
    }

    fn preview(
        &self,
        connection: &Connection,
        schema: &str,
        table: &str,
        limit: u64,
    ) -> Result<QueryOutput> {
        let mut client = postgres_connection(connection)?;
        let sql = format!(
            "select * from {}.{} limit {}",
            quote_identifier(schema),
            quote_identifier(table),
            limit.clamp(1, 10_000)
        );
        collect_query(&mut client, &sql, &[])
    }

    fn update_cell(&self, connection: &Connection, update: CellUpdate<'_>) -> Result<JsonValue> {
        if update.pk.is_empty() {
            return Err(anyhow!("cell update requires a primary key"));
        }

        let mut client = postgres_connection(connection)?;
        let target = column_meta(&mut client, update.schema, update.table, update.column)?;
        let mut values = vec![validated_value(update.value, &target)?];
        let mut filters = Vec::new();

        for (index, (column, value)) in update.pk.iter().enumerate() {
            let meta = column_meta(&mut client, update.schema, update.table, column)?;
            values.push(validated_value(value, &meta)?);
            filters.push(format!(
                "{} is not distinct from ${}::{}",
                quote_identifier(column),
                index + 2,
                meta.data_type
            ));
        }

        let params = values
            .iter()
            .map(|value| value as &(dyn ToSql + Sync))
            .collect::<Vec<_>>();
        let sql = format!(
            "update {}.{} set {} = $1::{} where {}",
            quote_identifier(update.schema),
            quote_identifier(update.table),
            quote_identifier(update.column),
            target.data_type,
            filters.join(" and ")
        );
        let changed = client
            .execute(&sql, &params)
            .context("failed to update PostgreSQL cell")?;
        Ok(json!({ "affected_rows": changed }))
    }

    fn query(&self, connection: &Connection, sql: &str) -> Result<QueryOutput> {
        let mut client = postgres_connection(connection)?;
        collect_query(&mut client, sql, &[])
    }
}

#[derive(Clone)]
struct ColumnMeta {
    data_type: String,
    nullable: bool,
}

fn postgres_connection(connection: &Connection) -> Result<Client> {
    let mut params = vec![
        format!("host={}", connection.host),
        format!("port={}", connection.port),
        format!("user={}", connection.user),
    ];

    if let Some(password) = &connection.password {
        params.push(format!("password={password}"));
    }

    if let Some(database) = &connection.database {
        params.push(format!("dbname={database}"));
    }

    Client::connect(&params.join(" "), NoTls).context("failed to connect to PostgreSQL")
}

fn list_columns(client: &mut Client, schema: &str, table: &str) -> Result<Vec<JsonValue>> {
    let rows = client.query(
        r#"
        select c.column_name,
               c.data_type,
               c.is_nullable,
               case when kcu.column_name is null then '' else 'PRI' end
        from information_schema.columns c
        left join information_schema.table_constraints tc
          on tc.table_schema = c.table_schema
         and tc.table_name = c.table_name
         and tc.constraint_type = 'PRIMARY KEY'
        left join information_schema.key_column_usage kcu
          on kcu.constraint_schema = tc.constraint_schema
         and kcu.constraint_name = tc.constraint_name
         and kcu.table_schema = c.table_schema
         and kcu.table_name = c.table_name
         and kcu.column_name = c.column_name
        where c.table_schema = $1 and c.table_name = $2
        order by c.ordinal_position
        "#,
        &[&schema, &table],
    )?;

    Ok(rows
        .into_iter()
        .map(|row| {
            json!({
                "name": row.get::<_, String>(0),
                "type": row.get::<_, String>(1),
                "nullable": row.get::<_, String>(2) == "YES",
                "key": row.get::<_, String>(3),
            })
        })
        .collect())
}

fn column_meta(client: &mut Client, schema: &str, table: &str, column: &str) -> Result<ColumnMeta> {
    list_columns(client, schema, table)?
        .into_iter()
        .find(|item| item["name"] == column)
        .map(|item| ColumnMeta {
            data_type: item["type"].as_str().unwrap_or_default().to_string(),
            nullable: item["nullable"].as_bool().unwrap_or(true),
        })
        .ok_or_else(|| anyhow!("unknown column {schema}.{table}.{column}"))
}

fn collect_query(
    client: &mut Client,
    sql: &str,
    params: &[&(dyn ToSql + Sync)],
) -> Result<QueryOutput> {
    let rows = client
        .query(sql, params)
        .context("failed to execute PostgreSQL query")?;
    let columns = rows
        .first()
        .map(|row| {
            row.columns()
                .iter()
                .map(|column| column.name().to_string())
                .collect()
        })
        .unwrap_or_default();
    let rows = rows.iter().map(row_to_json).collect::<Result<Vec<_>>>()?;

    Ok(QueryOutput {
        columns,
        rows,
        affected_rows: 0,
    })
}

fn validated_value(value: &JsonValue, meta: &ColumnMeta) -> Result<Option<String>> {
    if value.is_null() {
        if meta.nullable {
            return Ok(None);
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

    Ok(Some(text))
}

fn row_to_json(row: &Row) -> Result<Vec<JsonValue>> {
    row.columns()
        .iter()
        .enumerate()
        .map(|(index, column)| value_to_json(row, index, column.type_()))
        .collect()
}

fn value_to_json(row: &Row, index: usize, ty: &Type) -> Result<JsonValue> {
    if *ty == Type::BOOL {
        return Ok(row
            .try_get::<_, Option<bool>>(index)?
            .map(JsonValue::Bool)
            .unwrap_or(JsonValue::Null));
    }
    if *ty == Type::INT2 {
        return Ok(row
            .try_get::<_, Option<i16>>(index)?
            .map(|value| json!(value))
            .unwrap_or(JsonValue::Null));
    }
    if *ty == Type::INT4 {
        return Ok(row
            .try_get::<_, Option<i32>>(index)?
            .map(|value| json!(value))
            .unwrap_or(JsonValue::Null));
    }
    if *ty == Type::INT8 {
        return Ok(row
            .try_get::<_, Option<i64>>(index)?
            .map(|value| json!(value))
            .unwrap_or(JsonValue::Null));
    }
    if matches!(*ty, Type::FLOAT4 | Type::FLOAT8) {
        return Ok(row
            .try_get::<_, Option<f64>>(index)
            .or_else(|_| {
                row.try_get::<_, Option<f32>>(index)
                    .map(|v| v.map(f64::from))
            })?
            .map(|value| json!(value))
            .unwrap_or(JsonValue::Null));
    }

    Ok(row
        .try_get::<_, Option<String>>(index)?
        .map(JsonValue::String)
        .unwrap_or(JsonValue::Null))
}

fn numeric_type(data_type: &str) -> bool {
    matches!(
        data_type,
        "smallint"
            | "integer"
            | "bigint"
            | "decimal"
            | "numeric"
            | "real"
            | "double precision"
            | "smallserial"
            | "serial"
            | "bigserial"
    )
}

fn quote_identifier(identifier: &str) -> String {
    format!("\"{}\"", identifier.replace('"', "\"\""))
}
