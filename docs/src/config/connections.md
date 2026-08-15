# Connections

## In your config

```lua
require("dbclient").setup({
  connections = {
    dev = {
      adapter  = "mariadb",
      host     = "127.0.0.1",
      port     = 3306,
      user     = "app",
      password = "secret",
      database = "shop",
    },

    prod = {
      adapter  = "postgres",
      host     = "db.internal",
      database = "app",
      user     = "reader",
      access   = "read",
      color    = "red",
      ssh      = { host = "bastion", user = "deploy" },
    },
  },
})
```

| Field | Notes |
|---|---|
| `adapter` | `postgres`, `mariadb` (also MySQL), `sqlite` |
| `path` | SQLite only, instead of host and port |
| `access` | `write`, `read`, `sandbox` — see [Access levels](access.md) |
| `color` | the winbar and sidebar colour |
| `ssh` | a tunnel, opened on connect and closed with the session |

## Passwords

Three forms:

```lua
password = "secret"            -- a literal
password = "$SHOP_DB_PASSWORD" -- an environment variable
password = "`pass show db/shop`" -- a command, run when the connection opens
```

The command form runs at connect time, so nothing is stored and nothing is in
your config.

## From inside the client

`<leader>dC` opens the connection manager: `a` adds, `c` edits, `t` tests
without connecting, `x` deletes, `y` copies a detected connection into your
own store. Stored as JSON under `stdpath("data")`.

## Detection

See [Connecting](../start/connecting.md). Turn it off with
`detect = { enabled = false }`, or narrow it with `detect.sources`.
