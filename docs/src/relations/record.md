# The whole record

`K` inspects a value. `gK` inspects the record.

```text
main.orders   #1042  SO-2026-1042
2 parents · 0 related tables

  id           1042
  reference    SO-2026-1042
  customer_id  7
  status_id    1
  created_at   2026-03-01 09:14:00
  note         NULL

  ▾ customers  ← customer_id   #7  Alice Chen
      id          7
      name        Alice Chen
      email       alice@example.com
      created_at  2026-01-04
  ▾ order_status  ← status_id   #1  awaiting payment
      id    1
      name  awaiting payment
```

The row, the row behind every foreign key it holds, and a sample of everything
pointing back at it. One buffer, one keystroke.

It opens beside the data rather than replacing it, so you can read both.

There is no template and no per-table configuration. A table that declares its
keys gets a record page for free; one that declares none gets a plain row,
which is the right amount of help for a table that has said nothing. The
header counts what it found — `2 parents · 0 related tables` above, because in
this schema nothing points at an order.

## Folds do the work

Each section is a fold whose first line is its summary.

| Key | Effect |
|---|---|
| `zo` `zc` | open, close |
| `zM` | close them all — the page becomes an index |
| `zR` | open them all |
| `<CR>` | open that table properly, filtered to those rows |
| `gu` | reveal masked values |
| `gr` | fetch it again |
| `q` | close |

## Masked columns

Columns named in `ui.mask_columns` — password, token, secret and friends — are
hidden until `gu`. A record page should not spray a hash onto a shared screen.

It is a visible list, not inference: nothing is read from the values, and a
column stays visible however secret it looks.

## What it costs

Less than it looks. Parents are grouped by the table they point at, so three
keys into `customers` are one query rather than three; every child count
arrives in a single `union all`, so a table with twenty-three things pointing
at it costs one round trip rather than twenty-three; and child rows are only
fetched for children that have any.

On a real 66-table schema: an order with ten outgoing keys assembles in 21
queries and 16 milliseconds; the `customers` equivalent — the hub with 23
things pointing at it — in 10 queries and 9 milliseconds.
