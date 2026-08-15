# Connecting

`<leader>dd` opens the sidebar. With nothing configured it says:

```text
  no connections; press a to add one
```

## Adding one

`a`:

```text
add a connection

  name        dev
  adapter     mariadb          (postgres · mariadb · sqlite)
  host        127.0.0.1
  port        3306
  user        app
  password    $SHOP_DB_PASSWORD
  database    shop
  access      write            (write · read · sandbox)
  color       blue

t test   <CR> save   q cancel
```

`t` tries it without saving, which is the quickest way to check a password.

## Connecting

```text
▸ ○ reporting  (read)
▸ ○ shop
```

`○` closed, `●` open. Access is shown when it is not the default. `<CR>`
connects and expands in one keystroke:

```text
▸ ○ reporting  (read)
▾ ● shop
  ▸ main
```

## Connections you never configured

On start and on every `:cd`, DBClient reads what the project already has:
`.env`, `docker-compose.yml`, Rails' `database.yml`, and `.dbclient.lua`.
Those appear dimmed. Nothing is written anywhere until you press `y` on one in
the connection manager.

Turn it off with `detect = { enabled = false }`.

## If it fails

You get a panel naming the layer that broke. See [Connections that
fail](../errors/connections.md).
