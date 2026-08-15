# DBClient.nvim

A database client for Neovim with a Lua front end and a Rust core.

The design principle is that Neovim already knows how to edit text, and a
database client that works with that is better than one that works around it:

- **Result sets are ordinary buffers.** Edit cells with `ciw`, a visual block, a
  macro or `:%s/old/new/g`. `dd` stages a delete, `o` stages an insert, `u` is
  your undo. `:w` turns the difference into `UPDATE` / `INSERT` / `DELETE`,
  shows you the exact SQL, and applies it in one transaction.
- **Schemas are ordinary buffers too.** `gD` opens the real `CREATE TABLE`;
  editing it and writing produces a migration you can read and edit before it
  runs. Comparing two schemas opens Neovim's own diff mode, so `]c` and `dp`
  work without the plugin implementing a diff.
- **Nothing blocks the editor.** A long query keeps running while you work, and
  `<leader>dk` cancels it on the server.
- **No new verbs.** Text objects (`ic`, `ir`, `iC`), the jumplist for foreign
  keys, the quickfix list for reverse lookups, `vim.diagnostic` for SQL errors,
  and `g?` for the keys of whatever buffer you are in.

Supported backends: **MariaDB/MySQL**, **PostgreSQL**, **SQLite**.

## Screenshots

Generated from a real session by `scripts/capture_readme_screenshots.lua`; the
SVG sources sit beside the PNGs so a change in appearance is a readable diff.

![Sidebar and an editable data buffer](docs/screenshots/workspace.png)

Note what the grid is doing: `Łódź`, `Gdańsk` and `Kraków` line up because
widths are counted in display cells; `∅` is a SQL `NULL` while row 5's `NULL` is
the literal string; `has \| a pipe` and `two\nlines` are escaped so a row is
always one line.

![Editing a table as text](docs/screenshots/data-buffer.png)

`ciw` on a cell, `dd` on a row, then `:w`.

![A query buffer and its results](docs/screenshots/query-buffer.png)

## Status

Early software under active development, built with AI-assisted rapid
development. The core protocol, the editable data buffer and the safety rails
are covered by tests: 43 Rust, 130 Lua including an end-to-end suite driving
real buffers, and 32 adapter tests each against a live PostgreSQL and MariaDB
server. The adapters still want exercising against real production schemas
before a 1.0.

## Installation

With `lazy.nvim`:

```lua
{
  "DorianDevp/dbnvimer",
  build = "cargo build --release --manifest-path rust/dbclient-core/Cargo.toml",
  opts = {},
}
```

The Rust core is a single binary. `opts = {}` is enough to start: DBClient
looks for connections in your project before you configure anything.

## Zero configuration

On startup DBClient scans the project for databases it can already reach:

| source | what it reads |
| --- | --- |
| `.env`, `.env.local` | `DATABASE_URL`, `POSTGRES_*`, `MYSQL_*` |
| `docker-compose.yml` | postgres / mysql / mariadb services, published ports and credentials |
| `config/database.yml` | Rails environments |
| `.dbclient.lua` | a project-local connection table, gated behind a trust prompt |

Detected connections appear in the sidebar marked `project`. Press `y` in the
connection manager to copy one into your own store and edit it.

## Configuration

Connections can be managed entirely from inside the client — `<leader>dC`, then
`a` to add one — and are stored in
`stdpath("data")/dbclient/connections.json` with mode `0600`.

**Passwords are never written to that file.** A connection names where its
secret comes from:

```lua
require("dbclient").setup({
  connections = {
    local_pg = {
      adapter = "postgres",
      host = "127.0.0.1",
      port = 5432,
      user = "postgres",
      database = "shop",
      password_env = "PGPASSWORD",       -- read from the environment
    },

    prod = {
      adapter = "postgres",
      host = "10.0.0.5",
      user = "readonly",
      database = "shop",
      password_cmd = "pass show db/prod", -- read from a command
      access = "read",                    -- refuse anything that is not a read
      color = "red",                      -- every buffer's winbar turns red
      ssh = { host = "bastion" },         -- Host alias from ~/.ssh/config
    },

    staging = {
      adapter = "mariadb",
      host = "127.0.0.1",
      user = "app",
      database = "app",
      password_prompt = true,             -- ask once per Neovim session
      access = "sandbox",                 -- writes run, then always roll back
    },

    notes = { adapter = "sqlite", path = "~/notes.db" },
  },
})
```

### Access levels

| `access` | behaviour |
| --- | --- |
| `write` | the default |
| `read` | the **core** refuses any statement that does not return rows, so a UI bug cannot get around it |
| `sandbox` | writes execute inside a transaction that is always rolled back, so you see what *would* happen |

### Everything else

```lua
require("dbclient").setup({
  core = { command = nil, statement_timeout_ms = nil },
  ui = {
    sidebar_width = 38,
    result_height = 14,
    max_cell_width = 48,
    preview_limit = 200,
    query_limit = 5000,
    null_display = "∅",       -- distinct from the literal text "NULL"
    bool_display = { "true", "false" },
    row_stripes = true,
    winbar = true,
    virtual_fk = true,         -- show `→ users.id` beside foreign keys
  },
  keys = true,                 -- false registers no mappings at all
  detect = { enabled = true },
  store = { enabled = true },
  history = { enabled = true, limit = 1000 },
  guard = {
    confirm_unfiltered_writes = true,
    confirm_destructive = true,
  },
  codegen = {},                -- your own code generators
})
```

Set `vim.g.dbclient_leader` to change the global prefix from `<leader>d`.

## Safety

Running the right statement against the wrong database is the failure mode that
matters, so several things guard against it:

- A connection with a `color` paints the winbar of **every** buffer bound to it.
- `access = "read"` is enforced in the Rust core, not in the UI.
- `access = "sandbox"` executes and rolls back, reporting what would have
  changed.
- `DELETE`/`UPDATE` without a `WHERE`, and `DROP`/`TRUNCATE`, are flagged as
  `vim.diagnostic` entries as you type and require confirmation before running.
- Writes from the data buffer carry the values they were based on, so an
  `UPDATE` that would silently overwrite someone else's change fails instead.
- Data-buffer writes need a primary key; without one the buffer is read-only.

## Commands

| command | what it does |
| --- | --- |
| `:DBClient` / `:DBClientToggle` | open or toggle the sidebar |
| `:DBClientConnect [name]` | connect, or pick from a list |
| `:DBClientDisconnect [name]` | close one connection |
| `:DBClientConnections` | the connection manager |
| `:DBClientData [schema.]table` | open a table's data buffer |
| `:DBClientQuery` | run the statement at the cursor |
| `:DBClientQueryBuffer` | open the scratch query buffer |
| `:DBClientExplain[!]` | explain the statement (`!` for `ANALYZE`) |
| `:DBClientBegin` / `:DBClientCommit` / `:DBClientRollback` | session transactions |
| `:DBClientCancel` | cancel the running statement on the server |
| `:DBClientActivity` / `:DBClientLocks` | server session and lock monitors |
| `:DBClientSearch` | fuzzy-find any table or column |
| `:DBClientHistory` / `:DBClientLog` | query history, statement log |
| `:DBClientSchemaDiff` | diff two schemas in Neovim's diff mode |
| `:DBClientDDL schema.object` | open an object's DDL |
| `:DBClientGenerate schema.table [template]` | generate a struct, interface, schema |
| `:DBClientWatch [s] <sql>` | re-run a statement on a timer, highlighting what changed |
| `:DBClientProfile [n] <sql>` | time a statement over several runs |
| `:DBClientBroadcast [sql]` | run one statement on every open connection and compare |
| `:DBClientDiagram [schema]` | Mermaid entity relationship diagram |
| `:DBClientImport schema.table [file]` | import a CSV |
| `:DBClientNotebook` | executable ```sql blocks in this markdown buffer |
| `:DBClientSnapshot` / `:DBClientCompare` | save a result set, diff against a saved one |
| `:DBClientCompareConnections` | run one statement on two connections and diff |
| `:DBClientUndoLog` | writes DBClient made, and the SQL that undoes them |
| `:DBClientPipe <cmd>` | pipe the rows through a shell command |
| `:DBClientHelp` | every mapping in one buffer |
| `:DBClientRestart` | restart the core |

## Keyboard

Press `g?` in any DBClient buffer for the keys that apply there. This section is
generated from the same table that registers the mappings.

<!-- keys:start -->

### Global

Available everywhere; prefixed with `g:dbclient_leader` (default `<leader>d`).

| key | action |
| --- | --- |
| `<leader>dd` | toggle the object sidebar |
| `<leader>dc` | pick a connection |
| `<leader>dC` | manage connections |
| `<leader>dq` | open the scratch query buffer |
| `<leader>dQ` | run the whole query buffer |
| `<leader>ds` | search tables and columns |
| `<leader>dh` | query history |
| `<leader>dl` | statement log for this session |
| `<leader>da` | server activity monitor |
| `<leader>dL` | lock / blocking tree |
| `<leader>dk` | cancel the running statement |
| `<leader>db` | begin a transaction |
| `<leader>dm` | commit the transaction |
| `<leader>dr` | roll back the transaction |
| `<leader>dx` | close the active connection |
| `<leader>dw` | watch a statement on a timer |
| `<leader>dp` | time a statement over several runs |
| `<leader>dB` | run a statement on every connection |
| `<leader>dn` | turn this markdown buffer into a notebook |
| `<leader>du` | writes DBClient made, and how to undo them |
| `<leader>de` | entity relationship diagram for a schema |
| `<leader>di` | import a CSV into a table |
| `<leader>dv` | compare result sets or connections |

### Sidebar

Object tree: connections, schemas, tables, columns and routines.

| key | action |
| --- | --- |
| `<CR>` | open or toggle the node |
| `o` | open or toggle the node |
| `l` | expand the node |
| `h` | collapse the node or go to its parent |
| `gd` | open table data |
| `gs` | inspect the schema or table |
| `gD` | open the DDL buffer |
| `gq` | open a query buffer |
| `gi` | list indexes |
| `gz` | table and index sizes |
| `ge` | entity relationship diagram |
| `gG` | generate code from this table |
| `gI` | import a CSV into this table |
| `gy` | yank the qualified object name |
| `a` | add a connection |
| `c` | edit the connection |
| `x` | delete the stored connection |
| `t` | test the connection |
| `f` | filter the tree |
| `F` | clear the filter |
| `]t` | jump to the next table |
| `[t` | jump to the previous table |
| `r` | refresh the current node |
| `R` | drop the metadata cache and refresh |
| `q` | close the sidebar |
| `g?` | show this help |

### Data buffer

The data buffer is a normal modifiable buffer. Edit cells the way you edit any text: `ciw`, visual block, `:%s/old/new/g`, macros, `dd` to delete a row, `o` to add one. `u` undoes staged changes because it is Neovim's own undo. Writing the buffer with `:w` turns the difference against the fetched snapshot into `UPDATE`, `INSERT` and `DELETE` statements, shows them for confirmation and applies them in one transaction.

Only navigation and inspection are mapped, so nothing shadows an editing key.

| key | action |
| --- | --- |
| `K` | inspect the full cell value |
| `gd` | follow the foreign key under the cursor |
| `gu` | find rows referencing this one |
| `gs` | statistics for this column |
| `gS` | sort by this column |
| `gf` | filter rows with a WHERE expression |
| `gF` | clear the filter and sort |
| `gt` | transposed view of this row |
| `gh` | hide this column |
| `gH` | show all columns |
| `gn` | set this cell to SQL NULL |
| `gy` | yank cell, row or selection as... |
| `gp` | duplicate this row as a new INSERT |
| `gr` | reload from the database |
| `gD` | open the DDL for this table |
| `gG` | generate code from this table |
| `gI` | import a CSV into this table |
| `]c` | next cell |
| `[c` | previous cell |
| `]r` | next row |
| `[r` | previous row |
| `]p` | next page |
| `[p` | previous page |
| `g?` | show this help |

### Query buffer

A real `sql` buffer, so treesitter, completion and your own mappings apply. Statements are split by the core, which understands string literals, comments, dollar quoting and `DELIMITER`.

| key | action |
| --- | --- |
| `<C-CR>` | run the statement at the cursor _(n, i)_ |
| `<leader>dq` | run the statement or selection _(n, v)_ |
| `<leader>dQ` | run every statement in the buffer |
| `<leader>de` | explain the statement |
| `<leader>dE` | explain analyze the statement |
| `K` | describe the table or column under the cursor |
| `gd` | open the DDL for the table under the cursor |
| `g?` | show this help |

### Result buffer

Read-only grid. `:w name.csv` exports; the format follows the extension.

| key | action |
| --- | --- |
| `K` | inspect the full cell value |
| `gs` | statistics for this column |
| `gt` | transposed view of this row |
| `gy` | yank cell, row or selection as... |
| `ge` | export the result set |
| `gS` | save this result set as a snapshot |
| `gV` | compare with a saved snapshot |
| `g!` | pipe the rows through a shell command |
| `]c` | next cell |
| `[c` | previous cell |
| `]r` | next row |
| `[r` | previous row |
| `q` | close the result buffer |
| `g?` | show this help |

### DDL buffer

The object's `CREATE` statement as text. Edit it and `:w` to see the migration DBClient would run; nothing reaches the server until you confirm.

| key | action |
| --- | --- |
| `gr` | reload the DDL from the server |
| `gD` | diff against the server version |
| `q` | close the buffer |
| `g?` | show this help |

### Plan buffer

Query plan as a foldable tree. The costliest nodes are highlighted.

| key | action |
| --- | --- |
| `<CR>` | fold or unfold this node |
| `gj` | jump to the most expensive node |
| `gr` | run the plan again |
| `ga` | switch to EXPLAIN ANALYZE |
| `q` | close the plan |
| `g?` | show this help |

### Activity monitor

Live server sessions; refreshes on a timer.

| key | action |
| --- | --- |
| `x` | cancel the statement under the cursor |
| `X` | terminate the session under the cursor |
| `gr` | refresh now |
| `gt` | toggle auto refresh |
| `q` | close the monitor |
| `g?` | show this help |

### Connection manager

Add, edit and test connections without leaving Neovim.

| key | action |
| --- | --- |
| `<CR>` | connect |
| `a` | add a connection |
| `c` | edit the connection |
| `x` | delete the connection |
| `t` | test the connection |
| `y` | copy a detected connection into the store |
| `gr` | rescan the project |
| `q` | close the manager |
| `g?` | show this help |

### Text objects

Available in data and result buffers, in operator-pending and visual mode.

| key | action |
| --- | --- |
| `ic` | inner cell |
| `ac` | a cell, including its separator |
| `ir` | inner row |
| `ar` | a row, including the newline |
| `iC` | inner column, every row of it |
| `aC` | a column, including its separator |

<!-- keys:stop -->

## Notebooks

`:DBClientNotebook` turns a Markdown buffer into one where ```sql blocks run
with `<CR>` and write their answer back underneath as a table:

````markdown
<!-- @conn: staging -->

## Why did revenue drop in March?

```sql
select date_trunc('month', placed_at) as month, sum(total)
from orders group by 1 order by 1;
```
<!-- dbclient:result -->
`3 row(s) in 12 ms`

| month | sum |
| --- | ---: |
| 2026-01-01 | 1200.50 |
| 2026-02-01 |  210.00 |
| 2026-03-01 | 1255.25 |
<!-- dbclient:end -->
````

Re-running a block replaces its result rather than stacking another one, so the
document stays a document. It is a file, so it commits alongside the incident
it explains.

## The data buffer

Opening a table gives you a normal modifiable buffer:

```
shop.customers  ·  rows 1-200 of 4123  ·  order by id asc
id  | name    | city | note
----+---------+------+-----------
1   | Łódź    | PL   | ∅
2   | NULL    | DE   | literal null
3   | Kraków  | PL   | has \| pipe
4   | Gdańsk  | ∅    | two\nlines
```

Things worth knowing:

- `∅` is a SQL `NULL`. The literal text `NULL` renders as itself, and both
  survive a round trip through the buffer.
- Values containing a newline, a tab or the column separator are escaped
  (`\n`, `\t`, `\|`) so a row is always one line, and unescaped on write.
- Column widths are measured in display cells, so `Łódź` and CJK text line up.
- A cell too wide to show is truncated with `…`; editing a truncated cell is
  **refused** rather than silently shortening the stored value. Use `K` to edit
  the whole value instead.
- Row identity is tracked with extmarks and reconciled against the primary key,
  so reordering, deleting and line-wise edits attribute changes to the right
  row.
- `:w` shows the summary *and* the exact SQL, generated by the same code that
  will run it, before anything is applied.

## Query buffers

A query buffer is a real `sql` buffer. Statements are split by the Rust core,
which understands string literals, `--` and `/* */` comments, PostgreSQL dollar
quoting and MySQL's `DELIMITER`, so a semicolon inside a string or a stored
procedure body does not split a statement.

A `-- @conn: name` header binds a `.sql` file to a connection, so a directory of
per-environment queries can live in the repository.

`K` describes the table or column under the cursor from the cached schema, `gd`
opens its DDL, and completion (`omnifunc`, plus an `nvim-cmp` source when cmp is
installed) offers tables, columns and routines.

## Requirements

- Neovim 0.10 or newer (0.11+ recommended)
- A Rust toolchain to build the core, or a bundled binary for your platform
- `ssh` on `PATH` for tunnels

Run `:checkhealth dbclient` to verify all of the above, including that the core
binary's protocol version matches the plugin's.

## Development

```sh
# Rust: format, lint, test
cargo fmt --manifest-path rust/dbclient-core/Cargo.toml
cargo clippy --manifest-path rust/dbclient-core/Cargo.toml -- -D warnings
cargo test --manifest-path rust/dbclient-core/Cargo.toml

# Lua: unit and end-to-end tests (needs the core built)
cargo build --release --manifest-path rust/dbclient-core/Cargo.toml
nvim --headless -u NONE -i NONE -c "luafile tests/run.lua"

# Protocol smoke test over stdio
python3 scripts/protocol_smoke.py

# Regenerate the documentation from the mapping table
nvim --headless -u NONE -c "luafile scripts/generate_docs.lua"
```

## Architecture

```
lua/dbclient/
  core/client.lua      async JSON-RPC client for the daemon
  session.lua          many live connections, each with its own metadata cache
  keymap.lua           every mapping, once; g? and the docs are generated from it
  connections/         registry, store, project detection, manager UI
  data/diff.lua        buffer text -> change set (pure, tested)
  ddl/migrate.lua      DDL text -> migration (pure, tested)
  ui/grid.lua          reversible grid rendering (pure, tested)
  ui/…                 sidebar, data, query, results, ddl, explain, activity

rust/dbclient-core/
  server.rs            the daemon: one thread and one connection per session
  session.rs           the DbSession trait, access control, value classes
  sqlparse.rs          dialect-tolerant statement splitter
  adapters/            mariadb, postgres, sqlite
  tunnel.rs            SSH forwarding with a retained child process
```

The core is one long-lived process hosting many sessions. That is what makes
real transactions, server-side cancellation, and non-blocking queries possible;
the previous design spawned a process and opened a connection per command.

## License

MIT
