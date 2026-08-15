# Join paths

`<leader>dj`. Pick two tables and get the join written for you, following the
declared keys.

```sql
select o.*
from shop.orders o
join shop.customers c on c.id = o.customer_id
join shop.addresses a on a.id = c.address_id
limit 100;
```

## When there is more than one route

You are shown them and you choose.

```text
orders → addresses

  1. orders → customers → addresses          (2 joins)
  2. orders → order_items → warehouses → addresses  (3 joins)
```

Routes are searched shortest-first and capped, because a suggestion five joins
long is not a suggestion.

## The graph

Built once per schema from a single query for every foreign key, and cached.
On a 66-table schema with 97 keys that is about three milliseconds.

`<leader>dE` draws the same graph as an entity relationship diagram.

## Tables that cannot be joined

If no path of declared keys connects them, that is the answer. DBClient does
not guess at relationships from column names — a schema that has not declared
its keys has not said what relates to what, and inventing an answer would be
worse than admitting there is none.
