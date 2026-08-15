# Where things open

Opening the sidebar gives you two windows: the sidebar, and whatever you were
already in.

```text
sidebar 38 │ [no name] 69
```

Opening a table takes over that second window rather than splitting away from
it, the way a file explorer does.

```text
sidebar 38 │ main.orders 69
```

## The three places

```text
┌─────────────┬──────────────────────────────────────────────┐
│             │                                              │
│  sidebar    │   data, query buffers, records, plans        │
│  38 cols    │   the window you started in                  │
│  fixed      │                                              │
│             ├──────────────────────────────────────────────┤
│             │   results, errors, reports                   │
│             │   14 lines at the bottom                     │
└─────────────┴──────────────────────────────────────────────┘
```

Content you asked to look at takes over the window you are in. Panels that
belong *under* something — a result set beneath its query — open at the
bottom. A second thing you asked to look at, like a record view or a query
buffer, splits beside the first, because you usually want both.

## Windows accumulate

They do not close themselves. Open a table, transpose a row, look at the
record and run a query and you have five windows:

```text
sidebar 38 │ main.orders 22 │ query.sql 23 │ record 22 │ transposed 36
─────────────────────────────────────────────────────────────────────
results 108
```

That is not a bug so much as a consequence of nothing being modal — but it
means `q` is worth learning early.

| Key | Effect |
|---|---|
| `q` | close the DBClient panel you are in |
| `<C-w>o` | keep only the current window |
| `<C-w>h` `<C-w>l` | move left and right |
| `<C-w>w` | cycle |
| `<leader>dd` | toggle the sidebar |

`q` is bound in every DBClient panel — results, plans, records, errors, the
export editor, the connection manager, and the quick-query tab. It is *not*
bound in the data buffer or in a query buffer, because those are editable and
`q` starts a macro there. Close those with `:q` like any other buffer.

## The sidebar keeps its width

38 columns, with `winfixwidth`, so splits elsewhere do not squash it and it
does not grow. `ui.sidebar_width` changes it permanently; `<C-w>20>` changes
it for now.
