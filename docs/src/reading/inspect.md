# Inspecting a value

Three of these are floats: they open over what you are reading and `q` or
`<Esc>` dismisses them. Nothing is rearranged and nothing is left behind.

## One cell in full

`K` opens the cell under the cursor, formatted for what it is: JSON
pretty-printed, binary as a hex dump with an ASCII gutter, long text wrapped
rather than truncated.

It is a buffer, so edit it and `:w` writes that one cell — which is how you
change a value too long to sit in the grid.

## One row, readably

`gt` transposes the row under the cursor into a float:

```text
┌─ main.orders row 1 ────────────────┐
│ id           1042                  │
│ reference    SO-2026-1042          │
│ customer_id  7                     │
│ status_id    1                     │
│ created_at   2026-03-01 09:14:00   │
│ note         NULL                  │
└────────────────────────────────────┘
```

This is the answer to a table with fifty columns.

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

## The whole row, with what it relates to

`gK`. That one is not a float — see [The whole record](../relations/record.md).
