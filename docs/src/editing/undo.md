# Undo

## Before the write

`u`. It is Neovim's own undo, because the buffer is just text.

## After the write

`<leader>du` lists every write DBClient made, newest first, each with the
statement that puts it back.

```text
2026-03-04 09:12   dev   shop.orders

  applied
    update shop.orders set status = 'closed' where id = 12

  to undo
    update shop.orders set status = 'open' where id = 12
```

Nothing is run for you. The compensating statements open in a query buffer to
be read, checked and run like anything else.

## What it does not cover

This is not database undo and does not pretend to be. It covers writes
DBClient itself made through the data buffer, where the previous values are
known — which is enough for "what did I just set that to", at an hour when
reading a binlog is not appealing.

A statement you typed and ran yourself is in the [statement
log](../sql/buffer.md), not here.

## Trying something without keeping it

A connection with `access = "sandbox"` runs writes and then always rolls them
back. Useful for finding out what a statement would do to production data
without doing it.
