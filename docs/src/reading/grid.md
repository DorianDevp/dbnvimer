# Browsing a table

`<CR>` on a table. It takes the main window; the sidebar keeps its height.

```text
main.orders  ·  rows 1-3 of 3
id   │ reference    │ customer_id │ status_id │ created_at          │ note
─────┼──────────────┼─────────────┼───────────┼─────────────────────┼───────
1042 │ SO-2026-1042 │           7 │         1 │ 2026-03-01 09:14:00 │ NULL
1043 │ SO-2026-1043 │           8 │         3 │ 2026-03-01 11:02:31 │ urgent
1044 │ SO-2026-1044 │           7 │         2 │ 2026-03-02 08:40:12 │ NULL
```

Three header lines: the title with the row range, the column names, the rule.
The header stays pinned to the winbar while you scroll.

The winbar carries the connection and [the trail](../relations/trail.md):

```text
 shop   main.customers › [main.orders]
```

## Four things to know

**Widths are display cells, not bytes.** Accented text and CJK line up.

**Values are escaped, reversibly.** A newline shows as `\n`, a tab as `\t`,
the column rule as `\|`. Parsing the line back gives the original bytes.

**Colour means type.** Numbers, booleans, timestamps, JSON and binary each
have their own.

**A truncated value ends in `…` and cannot be edited in place.** The buffer
does not hold the rest. Use `K`.

## Moving

`]c` `[c` cell, `]r` `[r` row, `]p` `[p` page. `w` and `b` step between cells
rather than words.

Text objects: `ic` a cell, `ir` a row, `iC` a whole column blockwise. So
`yiC` yanks a column of 200 rows and `.` repeats it.
