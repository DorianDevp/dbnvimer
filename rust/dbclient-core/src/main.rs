mod adapter;
mod adapters;
mod tunnel;

use adapter::{CellUpdate, Connection, DbAdapter};
use adapters::mariadb::MariaDbAdapter;
use adapters::postgres::PostgresAdapter;
use adapters::sqlite::SqliteAdapter;
use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use serde::Deserialize;
use serde::Serialize;
use serde_json::{json, Value as JsonValue};
use std::collections::BTreeMap;
use std::io::{self, Read};
use tunnel::{close_tunnel, open_tunnel, SshConfig, TunnelHandle};

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    #[command(subcommand)]
    command: CommandKind,
}

#[derive(Subcommand)]
enum CommandKind {
    Schemas,
    Tables,
    Columns,
    Routines,
    Preview,
    UpdateCell,
    Query,
    TunnelOpen,
    TunnelClose,
}

#[derive(Debug, Deserialize)]
struct Request {
    adapter: Option<String>,
    connection: Option<Connection>,
    ssh: Option<SshConfig>,
    tunnel: Option<TunnelHandle>,
    schema: Option<String>,
    table: Option<String>,
    column: Option<String>,
    value: Option<JsonValue>,
    pk: Option<BTreeMap<String, JsonValue>>,
    limit: Option<u64>,
    sql: Option<String>,
}

fn main() {
    if let Err(error) = run() {
        let payload = json!({ "ok": false, "error": format!("{error:#}") });
        println!("{}", serde_json::to_string(&payload).unwrap());
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    let request = read_request()?;

    let payload = match cli.command {
        CommandKind::Schemas => json_ok(adapter(&request)?.schemas(connection(&request)?)?),
        CommandKind::Tables => json_ok(adapter(&request)?.tables(
            connection(&request)?,
            request.schema.as_deref().context("missing schema")?,
        )?),
        CommandKind::Columns => json_ok(adapter(&request)?.columns(
            connection(&request)?,
            request.schema.as_deref().context("missing schema")?,
            request.table.as_deref().context("missing table")?,
        )?),
        CommandKind::Routines => json_ok(adapter(&request)?.routines(
            connection(&request)?,
            request.schema.as_deref().context("missing schema")?,
        )?),
        CommandKind::Preview => json_ok(adapter(&request)?.preview(
            connection(&request)?,
            request.schema.as_deref().context("missing schema")?,
            request.table.as_deref().context("missing table")?,
            request.limit.unwrap_or(200),
        )?),
        CommandKind::UpdateCell => json_ok(adapter(&request)?.update_cell(
            connection(&request)?,
            CellUpdate {
                schema: request.schema.as_deref().context("missing schema")?,
                table: request.table.as_deref().context("missing table")?,
                column: request.column.as_deref().context("missing column")?,
                value: request.value.as_ref().unwrap_or(&JsonValue::Null),
                pk: request.pk.as_ref().context("missing primary key")?,
            },
        )?),
        CommandKind::Query => json_ok(adapter(&request)?.query(
            connection(&request)?,
            request.sql.as_deref().context("missing sql")?,
        )?),
        CommandKind::TunnelOpen => {
            json_ok(open_tunnel(request.ssh.context("missing ssh config")?)?)
        }
        CommandKind::TunnelClose => {
            close_tunnel(request.tunnel.context("missing tunnel handle")?)?;
            json_ok(json!({ "closed": true }))
        }
    };

    println!("{}", serde_json::to_string(&payload)?);
    Ok(())
}

fn read_request() -> Result<Request> {
    let mut stdin = String::new();
    io::stdin().read_to_string(&mut stdin)?;
    serde_json::from_str(&stdin).context("invalid JSON request")
}

fn adapter(request: &Request) -> Result<Box<dyn DbAdapter>> {
    match request.adapter.as_deref().unwrap_or("mariadb") {
        "mariadb" => Ok(Box::new(MariaDbAdapter)),
        "postgres" | "postgresql" => Ok(Box::new(PostgresAdapter)),
        "sqlite" | "sqlite3" => Ok(Box::new(SqliteAdapter)),
        name => anyhow::bail!("unknown database adapter: {name}"),
    }
}

fn connection(request: &Request) -> Result<&Connection> {
    request.connection.as_ref().context("missing connection")
}

fn json_ok<T: Serialize>(value: T) -> JsonValue {
    json!({ "ok": true, "data": value })
}
