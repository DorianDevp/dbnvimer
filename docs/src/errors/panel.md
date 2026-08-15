# The error panel

`<leader>d!`.

```text
syntax error
  1064   SQLSTATE 42000   mariadb

  1 │ select * FORM orders
             ^~~~

  the server could not parse this
  Parsing stopped at the marked position, so the mistake is at or just
  before it — a missing comma, an unclosed quote or bracket, or a keyword
  the server does not have.
```

The message area gets one line. The panel gets everything else, and it is
still there in five minutes.

## The facts the server handed over

A constraint violation carries more than a sentence, and all of it is shown:

```text
a referenced row does not exist
  1452   SQLSTATE 23000   mariadb

  the relationship does not hold
  The value has to exist on the other side of the key before this row can
  point at it. Insert the referenced row first, or correct the value.

    table       shop.orders
    column      customer_id
    constraint  fk_orders_customer
    references  customers.id
    value       9999
```

Every one of those fields is in the string MySQL sends. Nothing else parses
it.

On PostgreSQL you also get `DETAIL` and `HINT`, which are frequently the most
useful lines in the response and are routinely discarded.

## Errors that suggest their own fix

| Kind | Offers |
|---|---|
| aborted transaction | `r` to roll back and carry on |
| lock timeout, deadlock | `L` to show what is holding it |
| too many connections | `L` to show what is connected |

## History

`:DBClientErrors` lists everything that failed this session, newest first.
`:DBClientErrors!` clears it.
