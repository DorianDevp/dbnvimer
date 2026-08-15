//! `dbclient-core` — the Rust backend for DBClient.nvim.
//!
//! The primary entry point is `serve`, a long-lived JSON-RPC daemon spoken over
//! stdio. The one-shot subcommands are kept for scripting and for
//! `:checkhealth`.

mod adapters;
mod protocol;
mod server;
mod session;
mod sqlparse;
mod tunnel;

use anyhow::Result;
use clap::{Parser, Subcommand};
use serde_json::json;

#[derive(Parser)]
#[command(name = "dbclient-core", version, about)]
struct Cli {
    #[command(subcommand)]
    command: CommandKind,
}

#[derive(Subcommand)]
enum CommandKind {
    /// Run the JSON-RPC daemon on stdin/stdout.
    Serve,
    /// Print version and protocol information as JSON.
    Version,
    /// Split a SQL script read from stdin into statements.
    SplitSql,
}

fn main() {
    if let Err(error) = run() {
        let payload = json!({ "ok": false, "error": format!("{error:#}") });
        eprintln!("{}", serde_json::to_string(&payload).unwrap_or_default());
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    match Cli::parse().command {
        CommandKind::Serve => server::serve(),
        CommandKind::Version => {
            println!(
                "{}",
                serde_json::to_string(&json!({
                    "ok": true,
                    "data": {
                        "version": env!("CARGO_PKG_VERSION"),
                        "protocol": server::PROTOCOL_VERSION,
                    }
                }))?
            );
            Ok(())
        }
        CommandKind::SplitSql => {
            use std::io::Read;
            let mut sql = String::new();
            std::io::stdin().read_to_string(&mut sql)?;
            println!(
                "{}",
                serde_json::to_string(&json!({
                    "ok": true,
                    "data": { "statements": sqlparse::split(&sql) }
                }))?
            );
            Ok(())
        }
    }
}
