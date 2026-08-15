# The sidebar

`<leader>dd`. One line per node.

```text
▸ ○ reporting  (read)
▾ ● shop
  ▾ main
    ▸ customers
    ▸ order_status
    ▸ orders
```

## `<CR>` and `l` differ on a table

`l` expands it to its columns:

```text
    ▾ customers
        id  INTEGER  PK
        name  TEXT
        email  TEXT
```

`<CR>` opens its **data**. On a connection or schema, where nothing else is
possible, `<CR>` expands.

Full list: [Sidebar keys](../keys/sidebar.md).

## Width

38 columns with `winfixwidth`, so splits elsewhere do not squash it.
`ui.sidebar_width` changes it permanently, `<C-w>20>` for now.
