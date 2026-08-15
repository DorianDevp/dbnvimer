# Import

`<leader>di`, or `gI` on a table.

```text
import  orders.csv → shop.orders

  detected      1 204 rows, 5 columns, comma delimited, utf-8

  csv column        → table column
  ─────────────────────────────────────
  Reference         → reference
  Customer          → customer_id
  Placed            → created_at
  Status            → status_id
  Notes             → (skipped)

  first row is header    yes
  on conflict            skip        (skip · update · fail)
  batch size             500

gp preview   gr import   q cancel
```

The delimiter, encoding and header are detected and shown as settings you can
correct.

## Mapping

Columns are matched by name first, then by position. A column you do not want
maps to `(skipped)`.

## Preview before writing

`gp` shows the rows that would be inserted, after conversion, so a date in the
wrong format is visible before 1 204 of them go in.

## The write

Batched inside one transaction. A failure rolls the whole import back and the
error names the CSV line, not the batch.

Values are checked against the schema the same way [an
edit](../editing/constraints.md) is, so a value the column will not hold is
reported before the server is asked.
