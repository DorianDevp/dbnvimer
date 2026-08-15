# Connecting

Press `<leader>dd`.

A panel opens on the left listing every connection DBClient knows about.

```text
connections

○ dev          detect  mariadb  127.0.0.1:3306/shop
○ prod         setup   postgres db.internal/app

a add   c edit   x delete   t test   <CR> connect   g? help
```

Put the cursor on one and press `<CR>`. The circle fills in, the name turns
green, and the tree expands to show the schema.

## Connections you never configured

`dev` above is marked `detect`. Nothing declared it: on start, and on every
`:cd`, DBClient walks up from the working directory reading files the project
already has.

| Source | What it reads |
|---|---|
| `env` | `.env`, `.env.local`, and friends |
| `docker_compose` | service definitions and their environment |
| `database_yml` | Rails' `config/database.yml` |
| `dbclient_lua` | a `.dbclient.lua` you wrote yourself |

Detected connections are shown dimmed. Nothing is copied anywhere until you
press `y` on one in the connection manager, which turns it into a stored
connection you can edit.

## If it does not connect

You get a panel naming which layer broke, rather than one line about a
refused connection. See [Connections that will not
open](../errors/connections.md).
