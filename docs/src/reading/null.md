# NULL

SQL `NULL` renders as `NULL`, the way every other client shows it.

```text
id  │ note
────┼───────────
  1 │ NULL
  2 │ urgent
  3 │ \NULL
```

Row 3 holds the four-letter *string*. It is written `\NULL` because this
buffer is editable and round trips through text: if the SQL value and the
string rendered identically, `:w` could not tell which one you meant.

One backslash is a smaller price than an unfamiliar symbol, and it only ever
appears on a value that would otherwise collide.

## Setting a cell to NULL

`gn`. Typing the letters `NULL` does the same thing; typing `\NULL` stores the
string.

## Changing the sentinel

```lua
require("dbclient").setup({ ui = { null_display = "∅" } })
```

The collision moves with it. With `∅` as the sentinel, `NULL` is an ordinary
string and needs no escape.

## In exports

`NULL` is written unquoted even when everything else is quoted, so an empty
quoted field means an empty string and nothing at all means `NULL`. A table
survives the round trip through CSV. See [Formats](../export/formats.md).
