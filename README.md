# DBClient.nvim

DBClient.nvim is a Neovim database client with a Lua UI and a Rust core.

The first supported adapter is MariaDB. The adapter is lazy-loaded, so future
database adapters can provide their own Rust command surface without loading UI
or connection code until the user opens a connection.

## Status

This is an initial implementation. It provides:

- MariaDB connections through `dbclient-core`.
- SSH local forwarding support for database connections behind a jump host.
- A keyboard-first DataGrip-inspired Neovim UI.
- Query execution into scratch result buffers.
- A small adapter registry for lazy database backends.

## Requirements

- Neovim 0.10 or newer.
- Rust stable toolchain.
- `ssh` on `PATH` when using SSH tunnels.
- MariaDB access from the local machine or through SSH forwarding.

## Build

```sh
cargo build --release --manifest-path rust/dbclient-core/Cargo.toml
```

The binary is written to:

```text
rust/dbclient-core/target/release/dbclient-core
```

You can override the path in `setup()`.

## Setup

```lua
require("dbclient").setup({
  core = {
    command = vim.fn.getcwd() .. "/rust/dbclient-core/target/release/dbclient-core",
  },
  connections = {
    local_mariadb = {
      adapter = "mariadb",
      host = "127.0.0.1",
      port = 3306,
      user = "root",
      password = vim.env.MARIADB_PASSWORD,
      database = "app",
    },
    via_ssh = {
      adapter = "mariadb",
      host = "127.0.0.1",
      port = 3306,
      user = "app",
      password = vim.env.MARIADB_PASSWORD,
      database = "app",
      ssh = {
        host = "bastion.example.com",
        user = "deploy",
        port = 22,
        remote_host = "127.0.0.1",
        remote_port = 3306,
      },
    },
  },
})
```

## Commands

- `:DBClient` opens the database sidebar.
- `:DBClientConnect <name>` selects a configured connection.
- `:DBClientQuery` executes the selected SQL or current statement.
- `:DBClientClose` closes active tunnels.

## Keyboard

- `q` closes DBClient windows.
- `<CR>` opens the item under cursor.
- `r` refreshes schemas and tables.
- `e` opens a query buffer for the active connection.
- `<leader>dq` executes SQL from a query buffer.
- `<leader>dc` opens the connection picker.

## Adapter Shape

Adapters live under `lua/dbclient/adapters/<name>.lua` and are only loaded when
selected. Each adapter returns a table with:

- `connect(connection, config)`
- `close(handle)`
- `schemas(handle)`
- `tables(handle, schema)`
- `columns(handle, schema, table)`
- `query(handle, sql)`

This keeps DB-specific code outside the UI and lets new adapters remain lazy.

## Documentation Log

The git history documents each implementation step with small commits. User
visible behavior is also covered in `doc/dbclient.txt`.
