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

### Working with results

- **`:DBClientWatch`** re-runs a statement on a timer and highlights the cells
  that changed since the previous run, which is the part a shell loop cannot do.
- **`:DBClientProfile`** times a statement over several runs and shows the
  distribution, so an outlier is visible instead of averaged away.
- **`:DBClientBroadcast`** runs one statement on every open connection and
  groups the connections by identical answers — the useful output for a sharded
  or multi-tenant setup is "do these all agree", not the rows themselves.
- **Snapshots**: save a result set to a file and diff it against a fresh run, or
  run the same statement on two connections and diff those, in Neovim's own
  diff mode.
- **`:DBClientPipe`** feeds the rows through a shell command as JSON lines.
- **`:DBClientImport`** imports a CSV with the column mapping edited as text and
  confirmed with `:w`, reusing the data buffer's change-set path so the type
  coercion, NULL handling and transaction are shared rather than reimplemented.
- **`:DBClientDiagram`** writes a Mermaid entity relationship diagram from the
  foreign key metadata: a text file that renders in GitHub and diffs like code.
- **Notebook mode**: ```sql blocks in a Markdown buffer run with `<CR>` and
  write their result back underneath. Re-running replaces the previous answer,
  so the document stays a document.
- **`:DBClientUndoLog`** records every write DBClient made together with the
  statement that would undo it, and opens it as SQL to read and run. It only
  covers DBClient's own writes and says so: a deleted row's other columns were
  never read, so it is not offered as recoverable.

### Navigating and writing queries

- **Quick query tab** (`<leader>d<CR>`): a SQL buffer above its results, in its
  own tab page. Nothing is named or saved until you ask; `<CR>` runs the
  statement under the cursor, and `gs` promotes it to a saved query.
- **Saved queries** (`<leader>df`), kept as `.sql` files with a small header,
  in two scopes: `.dbclient/queries/` beside the project, which the team shares
  through the repository, and a global store that is yours. `p` moves one
  between them. They are files, so they grep, diff and commit.
- **Walking relations**: `gd` follows a foreign key, `gU` goes the other way to
  the rows that reference this one, and `gu` lists every referencing table in
  the quickfix.
- **A navigation trail** behind those jumps. Each place — table plus filter,
  sort and page — is recorded, `g[` and `g]` walk it, a count jumps several
  steps at once, and `gb` opens the whole trail to jump anywhere in it. The
  breadcrumb sits in the winbar. Navigating from a rewound position drops the
  forward branch, the way a browser does.

### Export

Rebuilt around the parts other clients leave to a checkbox nobody finds. The
whole specification is an editable buffer written with `:w`, `gP` previews it
without writing, and presets exist because the settings that matter are not
independent of each other.

- **NULL survives.** The sentinel is configurable and written bare even under
  `quoting = all`, so an empty quoted field means an empty string and nothing
  means NULL. Every other tool renders both as nothing.
- **Excel actually opens the file.** The `excel` preset sets a UTF-8 BOM *and*
  CRLF *and* moves the delimiter to `;` when the decimal separator is a comma —
  which is what Excel itself does in those locales, and what a lone BOM toggle
  does not fix.
- **Memory stays flat.** Rows stream from a PostgreSQL cursor or a driver
  iterator and are written as they arrive; a five million row export costs what
  five rows cost. Tested at 5 000 rows across batch boundaries on both servers.
- **A JSON column is inlined**, so the output is one document rather than a
  document full of escaped documents. `json_columns` names them on backends
  with no JSON type, rather than guessing from a leading brace.
- **Every export explains itself.** A sidecar manifest records the statement,
  the columns and their types, the row count, every setting that changes how
  the bytes read back, and a SHA-256 per file.
- **Partitioning** by row count or by the value of a column, so per-day and
  per-tenant files need no shell loop. Gzip on the way out.
- **Redaction** masks named columns as they are written, which is the moment it
  is actually needed.
- **Real XLSX**, written without a dependency: numbers stay numeric so `SUM`
  works, `007` keeps its zeros, the header row is frozen.
- **SQL output** is batched multi-row inserts with an optional transaction,
  dialect-correct quoting and escaping, and upsert/ignore/replace modes.
- SHA-256 and CRC-32 are implemented here and checked against the published
  test vectors, rather than pulled in as dependencies to write a manifest and a
  zip header. The one new dependency is `flate2` for gzip and for deflating the
  XLSX container, with its pure-Rust backend so nothing links system zlib.

### Seeing what a statement will do

- **Blast radius.** Before an `UPDATE` or `DELETE` that would touch more than
  one row, the core rewrites it into the equivalent `SELECT` and the rows it
  would change are shown with the server's own count. The rewrite tracks
  parenthesis depth and ignores keywords inside literals and comments, and
  anything it cannot confidently rewrite — a multi-table delete, say — is
  refused rather than previewed as different rows.
- **The server validates the SQL.** Each statement is `PREPARE`d and discarded,
  so unknown columns, wrong types and syntax errors surface as
  `vim.diagnostic` entries carrying the server's own message and position,
  without executing anything. A static linter can only guess at names.
- **`:DBClientJoin`** searches the foreign key graph for a path between two
  tables and writes the query, aliases and `ON` clauses included. Edges are
  followed in either direction, several routes are offered when they exist, and
  the shortest comes first.
- **`:DBClientAudit`** lints a schema: tables with no primary key, foreign keys
  with no index behind them, indexes that are a prefix of another, foreign keys
  whose types disagree. With `!` it also reads column statistics and reports
  always-null, never-null and single-value columns. Findings go to the quickfix
  list.
- **`:DBClientChart`** draws a result set as bars, with a sparkline summary.
  Negative values sit either side of a zero line rather than being rescaled, and
  a column whose type the backend never declared is charted anyway when its
  values are numbers.

### Workspaces and diagnostics

- **`:DBClientWorkspaceSave` / `Restore`** remember which connections are open,
  which tables you had open with their filters and sorts, and your query buffer
  contents, keyed by working directory and saved automatically on exit.
  `:mksession` cannot do this: restoring a data buffer means reconnecting and
  re-running its query, not restoring bytes.
- **`:DBClientIndexes`** surfaces index usage counters and unused index
  candidates, which the core already collected but nothing exposed.
- **Sticky header**: once the header row scrolls out of sight, the column names
  appear in the winbar, matched to the horizontal scroll.
- The value inspector can write a blob out to a file (`gw`), which is more
  useful than pretending a terminal will render it.

### Testing

- 102 Rust unit tests, 233 Lua tests (including an end-to-end suite driving real
  buffers against a real database), and 49 adapter tests each against a live
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
