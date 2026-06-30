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
- Data preview buffers with explicit primary-key guarded cell updates.
- Schema/object inspection buffers separate from data buffers.
- Procedure/function discovery with query-buffer call seeding.
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
- `:DBClientQueryTab` opens or focuses the query buffer.
- `:DBClientData <schema.table>` opens a table preview buffer.
- `:DBClientClose` closes active tunnels.

## Keyboard

- `q` closes DBClient windows.
- `<CR>` opens the item under cursor.
- `o` opens the item under cursor.
- `gd` opens table data for the focused table.
- `gs` opens schema or table inspection.
- `gq` opens or focuses the query buffer.
- `]t` / `[t` jump between visible tables.
- `s` searches visible table names.
- `n` repeats the last table-name match.
- `r` refreshes schemas and tables.
- `e` opens a query buffer for the active connection.
- `F` toggles fullscreen for DBClient windows.
- In data buffers, `]c` / `[c` move cells, `]r` / `[r` move rows, and `E` edits the current cell.
- `<leader>dq` executes SQL from a query buffer.
- `<C-CR>` executes SQL from normal or insert mode in a query buffer.
- `<leader>dc` opens the connection picker.

## Adapter Shape

Adapters live under `lua/dbclient/adapters/<name>.lua` and are only loaded when
selected. Each adapter returns a table with:

- `connect(connection, config)`
- `close(handle)`
- `schemas(handle)`
- `tables(handle, schema)`
- `columns(handle, schema, table)`
- `routines(handle, schema)`
- `preview(handle, schema, table, limit)`
- `update_cell(handle, schema, table, column, value, pk)`
- `query(handle, sql)`

This keeps DB-specific code outside the UI and lets new adapters remain lazy.
The Rust core mirrors this with a `DbAdapter` trait; MariaDB-specific SQL,
identifier quoting, and value validation live in the MariaDB adapter module.

## Documentation Log

The git history documents each implementation step with small commits. User
visible behavior is also covered in `doc/dbclient.txt`, and release-level notes
are kept in `CHANGELOG.md`.

## Development Checks

```sh
cargo fmt --manifest-path rust/dbclient-core/Cargo.toml
cargo check --manifest-path rust/dbclient-core/Cargo.toml
nvim --headless -u NONE -i NONE -c "set rtp+=." -c "lua require('dbclient').setup({ connections = {} })" -c "qa"
```
