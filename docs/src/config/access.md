# Access levels

Every connection has one. Set it before you point anything at production.

| Level | Behaviour |
|---|---|
| `write` | the default; everything is allowed |
| `read` | anything that is not a `SELECT` is refused before it is sent |
| `sandbox` | writes run, then always roll back |

```lua
prod = { adapter = "postgres", host = "db.internal", access = "read" }
```

## Enforced in the core

Not in the interface. The Rust daemon classifies every statement and refuses
the ones the level does not allow, so nothing in the front end — a mapping, a
plugin, a mistake — can talk its way past it.

A refusal is reported as DBClient's own, not as a database error:

```text
this connection is read-only, so `delete` was not run

  DBClient refused this, the server never saw it
  The connection is configured `access = "read"`. `:DBClientConnections`
  changes it; `sandbox` runs writes and always rolls them back.
```

## Sandbox

Runs the write inside a transaction and rolls it back whatever happens. The
row counts are real, the errors are real, and the data is untouched.

It is the honest way to answer "what would this do to production" — better
than reasoning about it, and better than a copy of the data that is three
weeks old.

## Colour

`color = "red"` makes the connection unmistakable in the winbar and the
sidebar. Available names: `red`, `orange`, `amber`, `green`, `teal`, `cyan`,
`blue`, `violet`, `magenta`, `grey`.

Like every other colour, they are generated against your colourscheme's
background, so they stay legible on a light theme.
