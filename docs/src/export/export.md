# Export

`<leader>de` on a table or a result set, or `ge` inside one.

An editor opens: a buffer of settings, not a dialog.

```text
export  shop.orders → ~/exports/orders.csv

  format            csv
  delimiter         ,
  quoting           minimal
  null_as
  header            true
  encoding          utf-8
  bom               false
  decimal_separator .

  partition_rows    0
  compress          none
  manifest          true
  checksum          sha256
  redact

gp preset   gP preview   gr run   gs save as preset   q close
```

Every line is editable text, and `gP` previews the first rows without writing
anything.

## In a hurry

From a result buffer:

```vim
:w report.csv
:w report.xlsx
:w report.json
```

The format follows the extension.

## Streaming

Rows are fetched in batches through a server-side cursor, so memory stays flat
whether the table has a thousand rows or forty million. The row count in the
manifest is the number actually written, not an estimate.

## The manifest

A sidecar recording the query, the connection, the row count, the byte count
and a SHA-256 of each file, so a file that arrives somewhere else can be
proved to be the one that left.

```json
{
  "generated": "2026-03-04T09:12:44Z",
  "connection": "dev",
  "query": "select * from shop.orders",
  "files": [
    { "path": "orders.csv", "rows": 1204, "bytes": 98211,
      "sha256": "9f2a…" }
  ]
}
```
