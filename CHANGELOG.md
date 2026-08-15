# Changelog

## Unreleased — 0.2.0

This release replaces the process-per-command core with a long-lived daemon and
rebuilds the UI around the idea that Neovim already knows how to edit text.
It is a breaking change: the wire protocol is new, so a stale `dbclient-core`
binary will be rejected with a clear message rather than misbehaving.

### Architecture

- **The core is now a daemon.** `dbclient-core serve` speaks newline-delimited
  JSON-RPC over stdio and hosts many sessions, each owning a thread and a live
  connection. Previously every command spawned a process and opened a fresh
  connection, which made real transactions impossible and paid a full connect
  for every tree expansion.
- **Nothing blocks the editor.** The Lua client is asynchronous, with a
  coroutine wrapper so call sites still read as straight-line code.
- **Statements can be cancelled on the server** — `pg_cancel_backend` on
  PostgreSQL, `KILL QUERY` on MariaDB, `sqlite3_interrupt` on SQLite.
- **Session transactions**: `:DBClientBegin` / `:DBClientCommit` /
  `:DBClientRollback`, with the state shown in the winbar.
- Several connections can be open at once, each with its own metadata cache.

### The data buffer is editable

- A data buffer is a normal modifiable buffer. `ciw`, visual block, `:%s/`,
  macros, `dd`, `o` and `u` all work; `:w` turns the difference against the
  fetched snapshot into `UPDATE` / `INSERT` / `DELETE`.
- The confirmation shows both a summary and the exact SQL, produced by the same
  code that will execute it.
- Row identity uses extmarks reconciled against the primary key, so line-wise
  edits, reordering and deletions attribute changes to the right record.
- Updates carry the values they were based on, so a concurrent change causes a
  clear failure instead of a silent overwrite.
- Filtering (`gf`), sorting (`gS`), paging (`]p`/`[p`), column hiding (`gh`),
  transposed rows (`gt`) and reverse-key lookup into the quickfix list (`gu`).
- `gd` follows a foreign key and pushes to the jumplist, so `<C-o>` comes back.
- Grid text objects `ic`/`ac`, `ir`/`ar`, `iC`/`aC` in operator-pending and
  visual mode; `w` and `b` step by cell.
- The old modal cell-edit popup and the bespoke transaction popup are gone:
  Neovim's own editing and undo replace them.

### Fixed

- **Column widths are measured in display cells, not bytes.** Any multibyte
  data — Polish text, CJK — used to shift every column after it.
- **Values containing a newline no longer break the buffer.** Newlines, tabs
  and the column separator are escaped reversibly (`\n`, `\t`, `\|`).
- **SQL `NULL` is now distinguishable from the literal text `"NULL"`**, in both
  directions, and it is no longer impossible to store the string `"NULL"`.
- **`DATE` columns no longer render a fabricated `00:00:00.000000`.**
- **Previews are ordered by primary key**, so row order is stable between
  refreshes and paging is meaningful.
- **Statement splitting understands SQL.** String literals, `--`, `#` and
  nested `/* */` comments, PostgreSQL dollar quoting and MySQL `DELIMITER` no
  longer split a statement at the wrong semicolon.
- **PostgreSQL values are fetched as text with types from a describe**, so
  arrays, ranges, enums, domains, `numeric(38,10)` and extension types all
  render correctly and keep full precision.
- **PostgreSQL parameters are cast server-side** (`$n::text::type`); the old
  form made the driver refuse to send a string for an `int8`.
- **MariaDB `json` columns are detected** through their `json_valid` check
  constraint, since MariaDB reports them as `longtext`.
- **Column metadata is fetched once per table**, not once per cell per key, so
  a batched update no longer does N+1 round trips inside its transaction.
- SSH tunnels: the child process handle is retained (no `kill` by a possibly
  recycled pid, and it works on Windows), the forwarded port is polled instead
  of slept on, a lost port race is retried, and `BatchMode` plus `ConnectTimeout`
  stop a tunnel hanging on a prompt. `~/.ssh/config` host aliases and
  `ProxyJump` are supported.

### Added

- **Connection management inside the client** (`<leader>dC`): add, edit, delete
  and test connections. Stored in `stdpath("data")/dbclient/connections.json`
  with mode 0600.
- **Passwords are never written to disk.** A connection names an environment
  variable, a shell command, or asks to be prompted once per session.
- **Zero-config project detection**: `.env`, `docker-compose.yml`,
  `config/database.yml` and a trust-gated `.dbclient.lua`.
- **`g?` shows the mappings for the current buffer**, generated from the same
  table that registers them — as are the README and `:help dbclient-keys`.
- **Safety rails**: `access = "read"` enforced in the core, `access = "sandbox"`
  that always rolls back, per-connection winbar colours, and confirmation for
  unfiltered or destructive statements.
- **SQL diagnostics** via `vim.diagnostic`: unfiltered writes, destructive
  statements, cartesian joins and unbounded selects, as you type.
- **Schema-aware completion** (`omnifunc` plus an `nvim-cmp` source), `K` hover
  for tables and columns, and `gd` to an object's DDL.
- **DDL round-trip**: `gD` opens a `CREATE` statement; editing and writing it
  produces a migration in an editable SQL buffer rather than applying a guess.
- **Schema diffing** through Neovim's own diff mode.
- **Query plans as a foldable tree**, with cost heat and estimate-vs-actual
  misestimates called out.
- **Server monitors**: `:DBClientActivity` and `:DBClientLocks`, with cancel and
  terminate on the row under the cursor.
- **Value inspector** (`K`): full values, pretty-printed JSON, decoded JWTs,
  base64 and unix timestamps, hex dumps for blobs.
- **Column statistics** (`gs`) with distinct counts and a top-values histogram.
- **Export** to CSV, TSV, JSON, JSONL, Markdown and `INSERT` statements —
  `:w report.csv` on a result buffer picks the format from the extension.
- **Code generation** for Go, TypeScript, Rust, Python, Zod and SQL, with
  user-supplied templates.
- **Query history** and a per-session statement log.
- **Object search** across every cached table and column.
- `:checkhealth dbclient`, including a core protocol version check.

### Testing

- 43 Rust unit tests, 116 Lua tests (including an end-to-end suite driving real
  buffers against a real database), and 32 adapter tests each against a live
  PostgreSQL and MariaDB server.
- `scripts/protocol_smoke.py` exercises the wire protocol over stdio.
- `scripts/ui_smoke.lua` drives the real UI headlessly and prints every buffer.
- CI runs `cargo fmt --check`, `clippy -D warnings`, every suite, and verifies
  the generated documentation is in sync.

### Removed

- The committed `bin/dbclient-core-*` binaries. They bloat every clone, live in
  git history forever, and the one that was there spoke the old protocol.
  Release binaries are now attached to GitHub Releases; `lazy.nvim` users can
  build with `build = "cargo build --release --manifest-path …"`.

## 0.1.0 — Initial implementation

- Initialized the plugin as MIT-licensed software.
- Added `dbclient-core`, a Rust JSON CLI for MariaDB metadata and query calls.
- Added PostgreSQL and SQLite adapters behind the same Lua/Rust interfaces.
- Added SSH local tunnel open/close support through the Rust core.
- Added a lazy Lua adapter registry, state management and a metadata cache.
- Added a keyboard-first sidebar for connections, schemas, tables and columns.
- Added SQL query buffers, result grids, data buffers and inspection buffers.
- Added primary-key guarded cell updates and batched cell transactions.
- Added Neovim help documentation and setup examples.
