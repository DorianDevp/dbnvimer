# Inspecting

Three floats. `q` or `<Esc>` dismisses them and nothing is rearranged.

## `K` a cell in full

JSON pretty-printed, binary as a hex dump with an ASCII gutter, long text
wrapped rather than truncated.

It is a buffer, so edit it and `:w` writes that one cell. That is how you
change a value too long to sit in the grid.

## `gt` the row, transposed

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

## `gs` the column, statistically

```text
orders.status_id                               smallint

  rows            3
  distinct        3
  null            0
  min             1
  max             3
```

Answers "is this column actually used".

`gK` is not a float. See [The whole record](../relations/record.md).
