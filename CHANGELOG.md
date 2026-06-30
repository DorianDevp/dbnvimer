# Changelog

## 0.1.0 - Initial implementation

- Initialized the plugin as MIT-licensed software.
- Added `dbclient-core`, a Rust JSON CLI for MariaDB metadata and query calls.
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
- Added Neovim help documentation and setup examples.
