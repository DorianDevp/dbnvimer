# Where things open

Three places, always the same ones.

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

Content you asked to look at — a table, a query buffer — takes over the window
you were in rather than splitting away from it, the way a file explorer does.
Panels that belong *under* something, like a result set beneath its query,
open at the bottom.

## Moving between them

Vim's own window commands; nothing was invented.

| Key | Effect |
|---|---|
| `<C-w>h` `<C-w>l` | left and right |
| `<C-w>w` | cycle |
| `<C-w>o` | keep only this window |
| `q` | close a DBClient panel |
| `<leader>dd` | toggle the sidebar |

## The sidebar is deliberately narrow

It has `winfixwidth`, so other splits do not squash it and it does not grow.
Widen it permanently with `ui.sidebar_width`, or just for now with `<C-w>20>`
like any other window.
