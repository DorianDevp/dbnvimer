use anyhow::{anyhow, Context, Result};
use clap::{Parser, Subcommand};
use mysql::prelude::Queryable;
use mysql::{OptsBuilder, Pool, Row, Value};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value as JsonValue};
use std::io::{self, Read};
use std::net::TcpListener;
use std::process::{Command, Stdio};

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
    Query,
    TunnelOpen,
    TunnelClose,
}

#[derive(Debug, Deserialize)]
struct Request {
    connection: Option<Connection>,
    ssh: Option<SshConfig>,
    tunnel: Option<TunnelHandle>,
    schema: Option<String>,
    table: Option<String>,
    sql: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct Connection {
    host: String,
    #[serde(default = "default_mariadb_port")]
    port: u16,
    user: String,
    password: Option<String>,
    database: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
struct SshConfig {
    host: String,
    user: Option<String>,
    #[serde(default = "default_ssh_port")]
    port: u16,
    identity_file: Option<String>,
    #[serde(default = "default_local_host")]
    local_host: String,
    local_port: Option<u16>,
    #[serde(default = "default_remote_host")]
    remote_host: String,
    #[serde(default = "default_mariadb_port")]
    remote_port: u16,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct TunnelHandle {
    pid: u32,
    local_host: String,
    local_port: u16,
    remote_host: String,
    remote_port: u16,
}

#[derive(Debug, Serialize)]
struct QueryOutput {
    columns: Vec<String>,
    rows: Vec<Vec<JsonValue>>,
    affected_rows: u64,
}

fn main() {
    if let Err(error) = run() {
        let payload = json!({ "ok": false, "error": error.to_string() });
        println!("{}", serde_json::to_string(&payload).unwrap());
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    let request = read_request()?;

    let payload = match cli.command {
        CommandKind::Schemas => json_ok(list_schemas(connection(&request)?)?),
        CommandKind::Tables => json_ok(list_tables(
            connection(&request)?,
            request.schema.as_deref().context("missing schema")?,
        )?),
        CommandKind::Columns => json_ok(list_columns(
            connection(&request)?,
            request.schema.as_deref().context("missing schema")?,
            request.table.as_deref().context("missing table")?,
        )?),
        CommandKind::Query => json_ok(run_query(
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

fn connection(request: &Request) -> Result<&Connection> {
    request.connection.as_ref().context("missing connection")
}

fn json_ok<T: Serialize>(value: T) -> JsonValue {
    json!({ "ok": true, "data": value })
}

fn list_schemas(connection: &Connection) -> Result<Vec<String>> {
    let mut conn = mysql_connection(connection)?;
    conn.query_map(
        "select schema_name from information_schema.schemata order by schema_name",
        |schema: String| schema,
    )
    .context("failed to list schemas")
}

fn list_tables(connection: &Connection, schema: &str) -> Result<Vec<JsonValue>> {
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

fn list_columns(connection: &Connection, schema: &str, table: &str) -> Result<Vec<JsonValue>> {
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

fn run_query(connection: &Connection, sql: &str) -> Result<QueryOutput> {
    let mut conn = mysql_connection(connection)?;
    let mut result = conn.query_iter(sql).context("failed to execute query")?;
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

fn open_tunnel(ssh: SshConfig) -> Result<TunnelHandle> {
    let local_port = match ssh.local_port {
        Some(0) | None => free_port(&ssh.local_host)?,
        Some(port) => port,
    };
    let destination = format!(
        "{}:{}:{}:{}",
        ssh.local_host, local_port, ssh.remote_host, ssh.remote_port
    );
    let target = match &ssh.user {
        Some(user) => format!("{user}@{}", ssh.host),
        None => ssh.host.clone(),
    };

    let mut command = Command::new("ssh");
    command
        .arg("-N")
        .arg("-L")
        .arg(destination)
        .arg("-p")
        .arg(ssh.port.to_string())
        .arg("-o")
        .arg("ExitOnForwardFailure=yes")
        .arg("-o")
        .arg("ServerAliveInterval=30");

    if let Some(identity_file) = &ssh.identity_file {
        command.arg("-i").arg(identity_file);
    }

    let child = command
        .arg(target)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .context("failed to start ssh tunnel")?;

    Ok(TunnelHandle {
        pid: child.id(),
        local_host: ssh.local_host,
        local_port,
        remote_host: ssh.remote_host,
        remote_port: ssh.remote_port,
    })
}

fn close_tunnel(tunnel: TunnelHandle) -> Result<()> {
    let status = Command::new("kill")
        .arg(tunnel.pid.to_string())
        .status()
        .context("failed to stop ssh tunnel")?;
    if status.success() {
        Ok(())
    } else {
        Err(anyhow!("ssh tunnel process {} did not stop", tunnel.pid))
    }
}

fn free_port(host: &str) -> Result<u16> {
    let listener = TcpListener::bind((host, 0)).context("failed to reserve local tunnel port")?;
    Ok(listener.local_addr()?.port())
}

fn default_mariadb_port() -> u16 {
    3306
}

fn default_ssh_port() -> u16 {
    22
}

fn default_local_host() -> String {
    "127.0.0.1".to_string()
}

fn default_remote_host() -> String {
    "127.0.0.1".to_string()
}
