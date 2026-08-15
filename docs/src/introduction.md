# DBClient.nvim

A database client that behaves like the editor it lives in.

Every page here is one idea with one example. Read it in order the first time;
after that it is a reference, and the sidebar is the index.

## Four rules

Everything else follows from these, so knowing them means you can usually
guess how something works without looking it up.

**Everything is a buffer.** Table data, a schema definition, a query plan, an
export configuration, an error. Your mappings apply. Your plugins apply.
`/` searches them and the quickfix list walks them.

**`:w` is the commit.** The data buffer is modifiable text. Edit a cell with
`ciw`, delete a row with `dd`, run `:%s/old/new/g` across the page. Nothing
has reached the database. Writing the buffer turns the difference against
what was fetched into `UPDATE`, `INSERT` and `DELETE`, shows you them, and
applies them in one transaction.

**No invented verbs.** There is no "edit cell" command, because `ciw` exists.
No "undo" command, because `u` exists. Folds fold, marks mark, the jumplist
works. Where a grid needed new nouns it got text objects — `ic` is a cell,
`ir` a row, `iC` a whole column — so every operator you know composes with
them.

**Nothing blocks.** A Rust daemon holds the connections; the editor never
waits on the network. A query that takes a minute leaves you free to keep
typing, and `<leader>dk` cancels it on the server.

## What it talks to

PostgreSQL, MariaDB and MySQL, SQLite. One Rust binary, bundled for Linux,
macOS and Windows on x86-64 and aarch64.

## A note on the examples

Every example in this book uses the same imaginary schema: a shop, with
`orders`, `customers`, `order_items`, `products` and `order_status`. None of
it is real data.
