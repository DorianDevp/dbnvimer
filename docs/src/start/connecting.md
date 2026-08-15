# Connecting

Press `<leader>dd`, or run `:DBClient`.

## The first time

A 38-column panel opens on the left, the cursor goes into it, and — if you
have configured nothing and the project declares nothing — it says exactly
this:

```text
  no connections; press a to add one
```

That is the whole sidebar. Press `a`.

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

`t` tries the connection without saving it, which is the fastest way to find
out whether the password is right.

## Once there is something to connect to

```text
▸ ○ reporting  (read)
▸ ○ shop
```

One line per connection. `○` is closed, `●` is open, and the access level is
shown when it is not the default. Detected connections — the ones DBClient
found in your `.env` or `docker-compose.yml` without being told — appear in a
dimmer colour.

Put the cursor on one and press `<CR>`:

```text
▸ ○ reporting  (read)
▾ ● shop
  ▸ main
```

It connected and expanded in one keystroke. The schema is underneath.

## Connections you never configured

On start, and on every `:cd`, DBClient walks up from the working directory
reading files the project already has.

| Source | What it reads |
|---|---|
| `env` | `.env`, `.env.local`, and friends |
| `docker_compose` | service definitions and their environment |
| `database_yml` | Rails' `config/database.yml` |
| `dbclient_lua` | a `.dbclient.lua` you wrote yourself |

Nothing is copied anywhere until you press `y` on one in the connection
manager, which turns it into a stored connection you can edit.

## If it does not connect

You get a panel naming which layer broke, rather than one line about a refused
connection. See [Connections that will not open](../errors/connections.md).
