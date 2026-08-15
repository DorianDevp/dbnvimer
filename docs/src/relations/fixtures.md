# Fixtures

`gx` on a row, or `<leader>dF`. Extracts that row plus everything it needs, as
`INSERT` statements you can run into an empty database.

```sql
-- @conn: dev
-- fixture: 12 row(s) across 11 table(s)
-- Parents first, so the foreign keys are satisfiable in this order.

-- shop.order_status  (1 row(s))
insert into `shop`.`order_status` (`id`, `name`) values
  (1, 'awaiting payment');

-- shop.customers  (1 row(s))
insert into `shop`.`customers` (`id`, `name`, `email`) values
  (7, 'Alice Chen', 'alice@example.com');

-- shop.orders  (1 row(s))
insert into `shop`.`orders` (`id`, `reference`, `customer_id`, `status_id`) values
  (1042, 'SO-2026-1042', 7, 1);
```

The order is a topological sort of the foreign key graph, so the keys are
satisfiable as written.

## When no order exists

Two tables that reference each other have no valid insert order. Rather than
emitting something that will not run, it says so:

```text
-- ! These tables reference each other, so no linear order exists:
--   shop.service_areas
--   shop.warehouses
-- ! Insert them with the constraints deferred, or in two passes.
```

## How far it follows

Parents are followed to a depth of three by default, and children are capped
per table, because "everything related to this row" in a well-connected schema
is most of the database.
