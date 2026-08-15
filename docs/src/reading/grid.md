# The grid

`<CR>` on a table in the sidebar. The data fills the window you were in, and
the cursor moves there.

```text
main.orders  ·  rows 1-3 of 3
id   │ reference    │ customer_id │ status_id │ created_at          │ note
─────┼──────────────┼─────────────┼───────────┼─────────────────────┼───────
1042 │ SO-2026-1042 │           7 │         1 │ 2026-03-01 09:14:00 │ NULL
1043 │ SO-2026-1043 │           8 │         3 │ 2026-03-01 11:02:31 │ urgent
1044 │ SO-2026-1044 │           7 │         2 │ 2026-03-02 08:40:12 │ NULL
```

Three lines of header — the title with the row range, the column names, and
the rule — then the rows. The header stays pinned to the winbar while you
scroll.

The winbar carries the connection and where you are:

```text
 shop   main.customers › [main.orders]
```

That second part is [the trail](../relations/trail.md): it remembers you came
here from `customers`.

## Four things worth knowing

### Widths are display cells, not bytes

`Kraków` is six characters and seven bytes. Measuring in bytes shifts every
column after it. The grid measures in display cells, so accented text and CJK
line up, and double-width characters count as two.

### Values are escaped, reversibly

| In the data | In the buffer |
|---|---|
| newline | `\n` |
| tab | `\t` |
| the column rule | `\|` |

Parsing the line back gives the original bytes. That is what makes the buffer
safe to edit as text.

### Colour means type

Numbers, booleans, timestamps, JSON and binary each have their own, generated
to a measured contrast against your colourscheme's background. See
[Appearance](../config/appearance.md).

### A truncated value is marked

Anything cut to fit ends in `…` and is refused as an edit — the buffer does
not have the whole value, so writing it back would lose the rest. Use `K` to
open it in full.
