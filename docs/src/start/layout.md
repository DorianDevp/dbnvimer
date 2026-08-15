# Where things open

## A table takes the main window

Whatever you were editing, opening a table replaces it in that window. The
file is not lost. It stays in the buffer list, and `<C-o>` or `:b#` brings it
straight back.

```text
editing app.lua        app.lua 120x38
opened a table         main.orders 120x38
```

With the sidebar out, the sidebar keeps its full height and the table takes
the rest:

```text
sidebar open           sidebar 38x38 │ app.lua 81x38
opened a table         sidebar 38x38 │ main.orders 81x38
opened a second table  sidebar 38x38 │ main.customers 81x38
```

The second table *replaces* the first rather than splitting again. Getting
back to it is [the trail](../relations/trail.md), not window management.

With several files open it takes the largest one and leaves the rest alone:

```text
two files + sidebar    sidebar 38x38 │ app.lua 21x38 │ app.lua 59x38
opened a table         sidebar 38x38 │ app.lua 21x38 │ main.orders 59x38
```

## Three kinds of window

**The main area** is for content you asked to look at: a table, a query
buffer, a record, a plan.

**The bottom strip** is for panels that report on something else: a result set
under the query that produced it, an error under the statement that caused
it. Fourteen lines by default, `ui.result_height`.

**Floats** are for a quick look that you dismiss: `gt` for a transposed row,
`g?` for this buffer's keys, `K` for a value in full.

```text
splits   sidebar 38x38 │ main.orders 69x38
floats   transposed row 36x6
```

`q` closes a float and `<Esc>` does too, so they never accumulate.

## What does split

Asking for a second thing while looking at the first splits, because you
usually want both:

```text
opened a table         sidebar 38x38 │ main.orders 69x38
gK, the record         sidebar 38x38 │ main.orders 34x38 │ record 34x38
a query buffer         sidebar 38x38 │ orders 22 │ query.sql 23 │ record 22
ran the query          … and results 108x14 along the bottom
```

Five windows is a lot, and nothing closes itself, so `q` is worth learning
early.

| Key | Effect |
|---|---|
| `q` | close the DBClient panel or float you are in |
| `<C-w>o` | keep only the current window |
| `<C-w>h` `<C-w>l` | move left and right |
| `<C-w>w` | cycle |
| `<leader>dd` | toggle the sidebar |

`q` is bound in every panel and float: results, plans, records, errors, the
export editor, the connection manager, the quick-query tab. It is *not* bound
in the data buffer or in a query buffer, because those are editable and `q`
starts a macro there. Close those with `:q`, or just open something else.

## The sidebar keeps its width

38 columns, with `winfixwidth`, so splits elsewhere do not squash it and it
does not grow. `ui.sidebar_width` changes it permanently; `<C-w>20>` changes
it for now.
