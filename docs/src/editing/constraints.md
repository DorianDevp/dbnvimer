# What the schema checks

The schema has already said what is legal. Type something it will not accept
and it is marked where you typed it, before anything is sent.

```text
id  │ label        │ status     │ priority
────┼──────────────┼────────────┼─────────
  1 │ ok           │ dispatched │ 40000
                     ~~~~~~~~~~   ~~~~~

`status` does not accept "dispatched"; one of: new, open, closed
40000 is beyond the range of smallint
```

These are real diagnostics, so `]d` steps between them and whatever you have
configured for diagnostics applies.

## What is checked

| Check | Example |
|---|---|
| `NOT NULL` | a required column left empty |
| length, in characters | `varchar(8)` given nine characters |
| integer range | `40000` in a `smallint`, `-1` in an unsigned column |
| decimal precision and scale | `12.345` in `decimal(6,2)` |
| enum and set membership | with the accepted values listed |
| boolean spellings | `7` in a `tinyint(1)` |
| JSON that parses | |
| uuid shape | |
| dates that exist | `2026-02-30`, with the real leap-year rule |

## What is not checked

Deliberately, because it cannot be done locally without a query per
keystroke:

- whether a foreign key's target row exists
- whether a `CHECK` expression holds
- uniqueness

Those still fail at the server, where [the error panel](../errors/panel.md)
explains them.

## The trade

A column that declares nothing produces no findings. The better the schema,
the more this can say, which is the right way round.
