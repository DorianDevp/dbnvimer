# The sidebar

`<leader>dd`. One line per node, four levels deep.

```text
▸ ○ reporting  (read)
▾ ● shop
  ▾ main
    ▸ customers
    ▸ order_status
    ▸ orders
```

`▸` and `▾` are closed and open. `○` and `●` are disconnected and connected.

It is deliberately terse: this is an index, not a report. Row counts, sizes
and definitions are one keystroke away rather than in your face on every line.

## `<CR>` versus `l`

They differ on a table node, and the difference is the point.

`l` expands it, so you can read the columns without leaving the tree:

```text
    ▾ customers
        id  INTEGER  PK
        name  TEXT
        email  TEXT
        created_at  TEXT
```

`<CR>` opens the table's **data** instead. On a connection or a schema, where
there is nothing else it could mean, `<CR>` expands.

| Key | Effect |
|---|---|
| `<CR>` `o` | connect, expand, or open the data — whatever the node is |
| `l` | expand |
| `h` | collapse, or jump to the parent |
| `]t` `[t` | next and previous table |
| `f` | filter the tree — type a few letters |
| `F` | clear the filter |
| `r` | refresh this node |
| `R` | drop the metadata cache and refresh |
| `q` | close the sidebar |

## Opening things from it

| Key | Opens |
|---|---|
| `gd` | the table's data (the same as `<CR>` on a table) |
| `gD` | its definition |
| `gq` | a query buffer bound to this connection |
| `gs` | an inspection of the schema or table |
| `gi` | its indexes |
| `gz` | table and index sizes |
| `ge` | an entity relationship diagram |
| `gj` | the join builder, starting here |
| `gA` | the schema audit |
| `gG` | generated code for this table |
| `gE` `gI` | export; import a CSV |
| `gy` | yanks the qualified name |

## Managing connections from it

`a` adds, `c` edits, `x` deletes, `t` tests without connecting, and `y` copies
a detected connection into your own store.

## It keeps its width

38 columns, with `winfixwidth`, so other splits do not squash it and it does
not grow. `ui.sidebar_width` changes it permanently; `<C-w>20>` changes it for
now.
