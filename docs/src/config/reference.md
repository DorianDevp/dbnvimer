# Every option

Pass only what you want to change.

```lua
require("dbclient").setup({
  ui = {
    sidebar_width  = 38,
    result_height  = 14,
    max_cell_width = 48,      -- longer values truncate with …
    preview_limit  = 200,     -- rows per page in a data buffer
    query_limit    = 5000,    -- cap on a query buffer's result
    null_display   = "NULL",
    bool_display   = { "true", "false" },
    row_stripes    = true,
    winbar         = true,
    sticky_header  = true,
    virtual_fk     = true,    -- show → table.column beside foreign keys
    grid_style     = "line",  -- or "ascii"

    mask_columns   = { "password", "passwd", "secret",
                       "token", "api_key", "private_key", "salt" },
    mask_with      = "••••••••",

    theme = { enabled = true, background = nil, foreground = nil,
              overrides = nil },
  },

  guard = {
    confirm_unfiltered_writes = true,
    confirm_destructive       = true,
    preview_writes_over       = 1,        -- false disables the preview
    typed_confirmation_for    = { "write" },
  },

  detect = {
    enabled = true,
    depth   = 4,              -- directories walked upward from the cwd
    sources = { "env", "docker_compose", "database_yml", "dbclient_lua" },
  },

  store   = { enabled = true, path = nil },
  history = { enabled = true, path = nil, limit = 1000 },
  export  = { dir = nil },
  log     = { limit = 500 },
  codegen = {},

  core = {
    command              = nil,   -- resolved automatically
    statement_timeout_ms = nil,   -- applied to every session that supports it
  },

  keys = true,   -- false registers no mappings at all
})
```

## Paths

`store`, `history` and `export` default to under `stdpath("data")/dbclient`.
Workspaces and saved statement snapshots sit beside the history file, so
pointing `history.path` elsewhere moves them all together.

## The leader prefix

```lua
vim.g.dbclient_leader = "<leader>b"   -- before setup()
```

## Statement timeout

```lua
core = { statement_timeout_ms = 30000 }
```

Applied server-side on every session that supports it, so a runaway query
stops on the server rather than being abandoned by the client.
