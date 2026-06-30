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
- Added Neovim help documentation and setup examples.
