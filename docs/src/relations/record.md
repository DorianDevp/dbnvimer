# The whole record

`K` inspects a value. `gK` inspects the record.

```text
shop.orders   #1042  SO-2026-1042
6 parents · 2 related tables

  id                    1042
  reference             SO-2026-1042
  customer_id           7

  ▾ order_status  ← status_id       #1  awaiting payment
  ▾ customers     ← customer_id     #7  Alice Chen
  ▾ order_items   → order_id        3 rows
      id  │ product      │ qty
      881 │ Widget       │   2
      882 │ Sprocket     │   1
```

The row, the row behind every foreign key it holds, and a sample of everything
pointing back at it. One buffer, one keystroke.

There is no template and no per-table configuration. A table that declares its
keys gets a record page for free; one that declares none gets a plain row,
which is the right amount of help for a table that has said nothing.

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
