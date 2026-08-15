# The grid

```text
id  │ reference    │ status_id │ created_at          │ note
────┼──────────────┼───────────┼─────────────────────┼──────
  1 │ SO-2026-1042 │         1 │ 2026-03-01 09:14:00 │ NULL
  2 │ SO-2026-1043 │         3 │ 2026-03-01 11:02:31 │ urgent
314 │ SO-2026-1355 │         1 │ 2026-03-03 18:44:07 │ a \| pipe
```

Four things in there are worth knowing.

## Widths are display cells, not bytes

`Kraków` is six characters and seven bytes. Measuring in bytes shifts every
column after it. The grid measures in display cells, so accented text and CJK
line up — and double-width characters count as two.

## Values are escaped, reversibly

| In the data | In the buffer |
|---|---|
| newline | `\n` |
| tab | `\t` |
| the column rule | `\|` |

Parsing the line back gives the original bytes. That is what makes the buffer
safe to edit as text.

## Colour means type

Numbers, booleans, timestamps, JSON and binary each have their own, generated
to a measured contrast against your colourscheme's background. See
[Appearance](../config/appearance.md).

## A truncated value is marked

Anything cut to fit ends in `…` and is refused as an edit — the buffer does
not have the whole value, so writing it back would lose the rest. Use `K` to
open it in full.
