# Key reference

Generated from the same table that registers the mappings, so it cannot
disagree with what is actually bound. `g?` in any DBClient buffer shows
that buffer's keys; `:DBClientHelp` shows every group at once.

## Global

Available everywhere; prefixed with `g:dbclient_leader` (default `<leader>d`).

| Key | Effect |
|---|---|
| `<leader>dd` | toggle the object sidebar |
| `<leader>dc` | pick a connection |
| `<leader>dC` | manage connections |
| `<leader>dq` | open the scratch query buffer |
| `<leader>dQ` | run the whole query buffer |
| `<leader>ds` | search tables and columns |
| `<leader>dh` | query history |
| `<leader>dl` | statement log for this session |
| `<leader>da` | server activity monitor |
| `<leader>dL` | lock / blocking tree |
| `<leader>dk` | cancel the running statement |
| `<leader>db` | begin a transaction |
| `<leader>dm` | commit the transaction |
| `<leader>dr` | roll back the transaction |
| `<leader>dx` | close the active connection |
| `<leader>dw` | watch a statement on a timer |
| `<leader>dp` | time a statement over several runs |
| `<leader>dB` | run a statement on every connection |
| `<leader>dn` | turn this markdown buffer into a notebook |
| `<leader>du` | writes DBClient made, and how to undo them |
| `<leader>dE` | entity relationship diagram for a schema |
| `<leader>di` | import a CSV into a table |
| `<leader>dv` | compare result sets or connections |
| `<leader>d<CR>` | quick query: type SQL, get rows |
| `<leader>df` | saved queries |
| `<leader>dS` | save the current query |
| `<leader>d[` | back along the navigation trail |
| `<leader>d]` | forward along the navigation trail |
| `<leader>dj` | build a join between two tables |
| `<leader>dA` | audit the schema for problems |
| `<leader>dg` | chart the current result set |
| `<leader>dR` | show what the statement would change |
| `<leader>de` | export a table or the last result |
| `<leader>dF` | extract a row plus everything it needs |
| `<leader>dI` | would this index help? |
| `<leader>dT` | follow changes as they are committed |
| `<leader>dM` | what this migration will lock, and for how long |
| `<leader>dD` | write the schema out as files |
| `<leader>dV` | compare the server against the committed schema |
| `<leader>d/` | find and replace across every table |
| `<leader>d!` | explain the last error in full |
| `<leader>dW` | what this server has been running, ranked |

## Sidebar

Object tree: connections, schemas, tables, columns and routines.

| Key | Effect |
|---|---|
| `<CR>` | open or toggle the node |
| `o` | open or toggle the node |
| `l` | expand the node |
| `h` | collapse the node or go to its parent |
| `gd` | open table data |
| `gs` | inspect the schema or table |
| `gD` | open the DDL buffer |
| `gq` | open a query buffer |
| `gi` | list indexes |
| `gz` | table and index sizes |
| `ge` | entity relationship diagram |
| `gj` | build a join from this table |
| `gA` | audit this schema |
| `gG` | generate code from this table |
| `gI` | import a CSV into this table |
| `gE` | export this table |
| `gy` | yank the qualified object name |
| `a` | add a connection |
| `c` | edit the connection |
| `x` | delete the stored connection |
| `t` | test the connection |
| `f` | filter the tree |
| `F` | clear the filter |
| `]t` | jump to the next table |
| `[t` | jump to the previous table |
| `r` | refresh the current node |
| `R` | drop the metadata cache and refresh |
| `q` | close the sidebar |
| `g?` | show this help |

## Data buffer

The data buffer is a normal modifiable buffer. Edit cells the way you edit any text: `ciw`, visual block, `:%s/old/new/g`, macros, `dd` to delete a row, `o` to add one. `u` undoes staged changes because it is Neovim's own undo. Writing the buffer with `:w` turns the difference against the fetched snapshot into `UPDATE`, `INSERT` and `DELETE` statements, shows them for confirmation and applies them in one transaction.

Only navigation and inspection are mapped, so nothing shadows an editing key.

| Key | Effect |
|---|---|
| `K` | inspect the full cell value |
| `gK` | the whole record: everything related to this row |
| `gd` | follow the foreign key under the cursor |
| `gU` | open the rows that reference this one |
| `gu` | list referencing rows in the quickfix |
| `g[` | back along the navigation trail |
| `g]` | forward along the navigation trail |
| `gb` | jump to any point on the trail |
| `gs` | statistics for this column |
| `gS` | sort by this column |
| `gf` | filter rows with a WHERE expression |
| `gF` | clear the filter and sort |
| `gt` | transposed view of this row |
| `gh` | hide this column |
| `gH` | show all columns |
| `gn` | set this cell to SQL NULL |
| `gy` | yank cell, row or selection as... |
| `gp` | duplicate this row as a new INSERT |
| `gx` | extract this row plus everything it needs |
| `gr` | reload from the database |
| `gD` | open the DDL for this table |
| `gG` | generate code from this table |
| `gI` | import a CSV into this table |
| `ge` | export this table |
| `]c` | next cell |
| `[c` | previous cell |
| `]r` | next row |
| `[r` | previous row |
| `]p` | next page |
| `[p` | previous page |
| `g?` | show this help |

## Quick query

A tab holding a SQL buffer above its results. Nothing is named or saved until you ask: type, run, read, move on. `<CR>` in normal mode runs the statement under the cursor, so a one-liner is three keystrokes from anywhere.

| Key | Effect |
|---|---|
| `<CR>` | run the statement under the cursor |
| `<C-CR>` | run it |
| `<leader>dQ` | run every statement |
| `gs` | save this query |
| `gf` | open a saved query |
| `gc` | run against another connection |
| `q` | close the tab |
| `g?` | show this help |

## Query buffer

A real `sql` buffer, so treesitter, completion and your own mappings apply. Statements are split by the core, which understands string literals, comments, dollar quoting and `DELIMITER`.

| Key | Effect |
|---|---|
| `<C-CR>` | run the statement at the cursor |
| `<leader>dq` | run the statement or selection |
| `<leader>dQ` | run every statement in the buffer |
| `<leader>de` | explain the statement |
| `<leader>dE` | explain analyze the statement |
| `<leader>dR` | show which rows this would change |
| `K` | describe the table or column under the cursor |
| `gd` | open the DDL for the table under the cursor |
| `gs` | save this query |
| `gf` | open a saved query |
| `g?` | show this help |

## Saved queries

Saved queries are `.sql` files with a `-- @name:` header, kept per project and globally. They are files, so they grep, diff and commit like anything else.

| Key | Effect |
|---|---|
| `<CR>` | open the query |
| `o` | open the query |
| `r` | run it without opening it |
| `n` | write a new query |
| `e` | rename it |
| `x` | delete it |
| `y` | yank the SQL |
| `p` | move between project and global |
| `gr` | rescan the query directories |
| `q` | close the browser |
| `g?` | show this help |

## Export editor

Every export setting as text in a buffer: edit it, `:w` runs it. A preset sets the settings that only make sense together — "for Excel" means a BOM *and* CRLF *and* a semicolon when the locale writes `1,5`.

| Key | Effect |
|---|---|
| `gp` | apply a preset |
| `gP` | preview without writing anything |
| `gs` | save these settings as a preset |
| `gr` | run the export |
| `q` | close without exporting |
| `g?` | show this help |

## Result buffer

Read-only grid. `:w name.csv` exports; the format follows the extension.

| Key | Effect |
|---|---|
| `K` | inspect the full cell value |
| `gs` | statistics for this column |
| `gt` | transposed view of this row |
| `gy` | yank cell, row or selection as... |
| `ge` | export: formats, encodings, partitioning |
| `gg` | chart these rows |
| `gS` | save this result set as a snapshot |
| `gV` | compare with a saved snapshot |
| `g!` | pipe the rows through a shell command |
| `]c` | next cell |
| `[c` | previous cell |
| `]r` | next row |
| `[r` | previous row |
| `q` | close the result buffer |
| `g?` | show this help |

## Record

One row with everything the schema says is connected to it: the row itself, the row behind every foreign key it holds, and a sample of every row that points back at it. Each section is a fold, so `zo`, `zc` and `zR` do what they always do.

| Key | Effect |
|---|---|
| `<CR>` | open this table, filtered to these rows |
| `gu` | reveal masked values |
| `gr` | fetch the record again |
| `q` | close the record |
| `g?` | show this help |

## Statement workload

Every statement the *server* has run, aggregated by it and ranked by total time rather than by average — which is what finds the query that takes four milliseconds eighty thousand times an hour. Snapshots compare against it later, so "this got eleven times slower" is a fact rather than a feeling.

| Key | Effect |
|---|---|
| `<CR>` | open it in a query buffer to fill in the parameters |
| `gy` | yank the statement |
| `s` | save the current counters |
| `c` | compare against a saved snapshot |
| `gr` | read the counters again |
| `q` | close |
| `g?` | show this help |

## DDL buffer

The object's `CREATE` statement as text. Edit it and `:w` to see the migration DBClient would run; nothing reaches the server until you confirm.

| Key | Effect |
|---|---|
| `gr` | reload the DDL from the server |
| `gD` | diff against the server version |
| `q` | close the buffer |
| `g?` | show this help |

## Plan buffer

Query plan as a foldable tree. The costliest nodes are highlighted.

| Key | Effect |
|---|---|
| `<CR>` | fold or unfold this node |
| `gj` | jump to the most expensive node |
| `gr` | run the plan again |
| `ga` | switch to EXPLAIN ANALYZE |
| `q` | close the plan |
| `g?` | show this help |

## Activity monitor

Live server sessions; refreshes on a timer.

| Key | Effect |
|---|---|
| `x` | cancel the statement under the cursor |
| `X` | terminate the session under the cursor |
| `gr` | refresh now |
| `gt` | toggle auto refresh |
| `q` | close the monitor |
| `g?` | show this help |

## Connection manager

Add, edit and test connections without leaving Neovim.

| Key | Effect |
|---|---|
| `<CR>` | connect |
| `a` | add a connection |
| `c` | edit the connection |
| `x` | delete the connection |
| `t` | test the connection |
| `y` | copy a detected connection into the store |
| `gr` | rescan the project |
| `q` | close the manager |
| `g?` | show this help |

## Text objects

Available in data and result buffers, in operator-pending and visual mode.

| Key | Effect |
|---|---|
| `ic` | inner cell |
| `ac` | a cell, including its separator |
| `ir` | inner row |
| `ar` | a row, including the newline |
| `iC` | inner column, every row of it |
| `aC` | a column, including its separator |

