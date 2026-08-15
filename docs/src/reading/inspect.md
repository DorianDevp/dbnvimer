# Inspecting a value

`K` opens the cell under the cursor in full, formatted for what it is.

```text
orders.note                                    text · 1 284 bytes

Customer called about the delayed shipment and asked for the
whole order to be held until the replacement part arrives.
```

JSON is pretty-printed, binary is shown as a hex dump with an ASCII gutter,
and a long text is wrapped rather than truncated.

```text
customers.preferences                          json · 214 bytes

{
  "newsletter": true,
  "locale": "en-GB",
  "channels": [ "email", "sms" ]
}
```

## Editing from the inspector

The inspector is a buffer. Edit it and `:w` writes that one cell — which is
how you change a value too long to sit in the grid.

## Column statistics

`gs` asks the server about the column rather than the cell.

```text
orders.status_id                               smallint

  rows        1 204
  distinct        4
  null            0
  min             1
  max             4
```

Useful for the question "is this column actually used", and for finding the
column that has been `NULL` in every row since 2019.
