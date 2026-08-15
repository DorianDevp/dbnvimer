# The sidebar

`<leader>dd`. Connections, schemas, tables, columns, routines.

```text
● dev                    mariadb 127.0.0.1:3306/shop
  ▾ shop
    ▸ orders             1 204 rows
    ▸ customers            340 rows
    ▸ order_items        4 118 rows
    ▸ products             112 rows
    ▸ order_status           4 rows
```

## Walking the tree

| Key | Effect |
|---|---|
| `<CR>` `o` | open or toggle the node |
| `l` | expand |
| `h` | collapse, or go to the parent |
| `]t` `[t` | next and previous table |
| `f` | filter the tree — type a few letters |
| `F` | clear the filter |
| `r` | refresh this node |
| `R` | drop the metadata cache and refresh |

## Opening things from it

| Key | Opens |
|---|---|
| `gd` | the table's data |
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
