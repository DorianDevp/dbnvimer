# Changelog

## Unreleased

- Added data-buffer cell transaction editing: `i` stages edits, `T` reviews
  pending changes, and commits apply all staged updates in one backend
  transaction.
- Added immediate data-buffer cell editing on `I`, with `E` kept as an
  immediate-update alias.
- Added `update-cells` support to the Rust core and Lua adapters for MariaDB,
  PostgreSQL, and SQLite.
- Changed cell edit popups to start empty while showing the old value in the
  title, avoiding accidental old-plus-new submissions for date values.
- Fixed cell edit submission so Neovim returns to normal mode after accepting
  an edit from insert mode.
- Documented `NULL` input handling for cell edits.

## 0.1.0 - Initial implementation

- Initialized the plugin as MIT-licensed software.
- Added `dbclient-core`, a Rust JSON CLI for MariaDB metadata and query calls.
- Added PostgreSQL and SQLite adapters behind the same Lua/Rust adapter
  interfaces.
- Added SSH local tunnel open/close support through the Rust core.
- Added a lazy Lua adapter registry with the first `mariadb` adapter.
- Added Lua state management for active connections and metadata cache.
- Added a keyboard-first sidebar for connections, schemas, tables, and columns.
- Added SQL query buffers and result-grid scratch buffers.
- Added failure hardening for adapter connection setup and SSH startup.
- Refactored the Rust core around a `DbAdapter` trait.
- Added routines, table previews, and primary-key guarded cell updates.
- Added Vim-native table search, table jumps, data buffers, inspection buffers,
  query-buffer focusing, and fullscreen toggles.
- Added reusable named scratch buffers to avoid `E95` reopen collisions.
- Added default Neovim highlight groups for tree, table, result, and inspect
  buffers.
- Added README screenshots generated from a real MariaDB Docker-backed DBClient
  session.
- Added Neovim help documentation and setup examples.
