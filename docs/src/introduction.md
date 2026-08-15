# DBClient.nvim

A database client that behaves like the editor it lives in.

Four rules explain most of it:

1. **Everything is a buffer.** Data, schemas, plans, errors. Your mappings and
   plugins apply.
2. **`:w` is the commit.** Edit the grid as text. Nothing reaches the database
   until you write the buffer.
3. **No invented verbs.** `ciw` edits a cell, `dd` deletes a row, `u` undoes,
   folds fold.
4. **Nothing blocks.** A Rust daemon holds the connections; the editor never
   waits on the network.

PostgreSQL, MariaDB and MySQL, SQLite.

Start with [Keybindings](keys/index.md) if you have it installed, or
[Install](start/install.md) if you do not.

Every example uses one imaginary shop: `orders`, `customers`, `order_items`,
`products`, `order_status`.
