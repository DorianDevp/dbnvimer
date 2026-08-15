# Following a key

Put the cursor on a foreign key cell and press `gd`.

```text
id  │ reference    │ customer_id │ status_id
────┼──────────────┼─────────────┼──────────
  1 │ SO-2026-1042 │           7 │         1
                        ↑ gd here
```

The `customers` table opens, filtered to `id = 7`. `gd` because it is
go-to-definition, and this is the same idea.

Foreign key columns are marked in the grid, and with `ui.virtual_fk` on you
also get `→ customers.id` as virtual text at the end of the line.

## The other direction

`gU` asks what points *at* this row. If several tables do, you choose.

```text
rows referencing customers #7

  orders            14 rows   where customer_id = '7'
  addresses          2 rows   where customer_id = '7'
  support_tickets    1 row    where customer_id = '7'
```

`gu` puts the same list in the quickfix, so `]q` walks it.

## When the key is NULL

Nothing to follow, and it says so rather than opening an empty table.
