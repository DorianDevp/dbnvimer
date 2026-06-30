use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;
use std::collections::BTreeMap;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Connection {
    pub host: String,
    #[serde(default = "default_mariadb_port")]
    pub port: u16,
    pub user: String,
    pub password: Option<String>,
    pub database: Option<String>,
    pub path: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct QueryOutput {
    pub columns: Vec<String>,
    pub rows: Vec<Vec<JsonValue>>,
    pub affected_rows: u64,
}

pub struct CellUpdate<'a> {
    pub schema: &'a str,
    pub table: &'a str,
    pub column: &'a str,
    pub value: &'a JsonValue,
    pub pk: &'a BTreeMap<String, JsonValue>,
}

pub trait DbAdapter {
    fn schemas(&self, connection: &Connection) -> Result<Vec<String>>;
    fn tables(&self, connection: &Connection, schema: &str) -> Result<Vec<JsonValue>>;
    fn columns(&self, connection: &Connection, schema: &str, table: &str)
        -> Result<Vec<JsonValue>>;
    fn routines(&self, connection: &Connection, schema: &str) -> Result<Vec<JsonValue>>;
    fn preview(
        &self,
        connection: &Connection,
        schema: &str,
        table: &str,
        limit: u64,
    ) -> Result<QueryOutput>;
    fn update_cell(&self, connection: &Connection, update: CellUpdate<'_>) -> Result<JsonValue>;
    fn query(&self, connection: &Connection, sql: &str) -> Result<QueryOutput>;
}

fn default_mariadb_port() -> u16 {
    3306
}
