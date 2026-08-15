# Inspecting a value

## One cell in full

`K` opens the cell under the cursor, formatted for what it is: JSON
pretty-printed, binary as a hex dump with an ASCII gutter, long text wrapped
rather than truncated.

The inspector is a buffer. Edit it and `:w` writes that one cell — which is
how you change a value too long to sit in the grid.

## One row, readably

`gt` transposes the row under the cursor into a small window of its own:

```text
id           1042
reference    SO-2026-1042
customer_id  7
status_id    1
created_at   2026-03-01 09:14:00
note         NULL
```

This is the answer to a table with fifty columns. It opens beside the data
rather than replacing it, so `q` closes it and you are back.

## One column, statistically

`gs` asks the server about the column rather than about the cell.

```text
orders.status_id                               smallint

  rows            3
  distinct        3
  null            0
  min             1
  max             3
```

Useful for "is this column actually used", and for finding the column that has
been `NULL` in every row since 2019.

## Windows pile up

`gt`, `gK` and the panels all open beside what you were looking at rather than
replacing it, because you usually want both. They do not close themselves:
`q` closes the one you are in, and `<C-w>o` keeps only the current window when
it has got out of hand.
