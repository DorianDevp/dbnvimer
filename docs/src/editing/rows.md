# Adding and deleting rows

## Adding

`o` opens a blank line. Type the values separated by `│`; nothing has to line
up.

```text
  1 │ SO-2026-1042 │ 1 │ 2026-03-01 09:14:00 │ NULL
 │ SO-2026-1400 │ 1 │ 2026-03-04 08:00:00 │
```

Leave a cell empty for a column that defaults or auto-increments. A `NOT NULL`
column with no default is reported before the write goes out.

`gp` on an existing row duplicates it as a new insert, which is usually
faster than typing.

## Deleting

`dd`, `dap`, a visual selection, any way you delete lines in Vim. Deletes are
keyed by primary key, so what disappears is what you deleted.

## Importing many rows

`gI` on a table, or `<leader>di`.

```text
import  orders.csv → shop.orders            1 204 rows

  csv column        → table column
  ─────────────────────────────────────
  Reference         → reference
  Customer          → customer_id
  Placed            → created_at
  Notes             → (skipped)

  first row is a header        yes
  on conflict                  skip

gp preview   gr import   q cancel
```

The preview shows the rows that would be inserted, and the import runs in
batches inside one transaction.
