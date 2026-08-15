# Replace everywhere

`<leader>d/`. The company changed its name and it is written in eleven places
you do not remember.

```text
shop   ACME Corp  →  ACME S.A.

  customers        company         3
  addresses        company        11
  invoices         note            1

15 rows across 3 columns in 3 tables (66 tables searched)
9 more row(s) match if case is ignored, and would not be changed
```

**Nothing has been written.** Search and replace are separate steps, always.

| Key | Effect |
|---|---|
| `<CR>` | open the matching rows so you can look |
| `r` | apply it, in one transaction, after one more confirmation |

## Why the last line is there

`LIKE` on MySQL uses the column's collation, which is case-insensitive by
default, while `replace()` compares bytes. A search that used `LIKE` would
promise fifteen changes and make six.

So the search uses the same comparison `replace()` does, and rows that match
only when case is ignored are counted separately and reported as such. The
number shown is the number that will change.

## No pattern language

Because there is no `LIKE`, the text you type is text. Searching for `100%`
finds `100%`, not every row in the database.

## Speed

One query per table, not per column. 51 searchable tables in about 19
milliseconds.
