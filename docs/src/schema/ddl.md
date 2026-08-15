# DDL buffers

`gD` on a table, in the sidebar or in a data buffer.

```sql
create table `orders` (
  `id` int unsigned not null auto_increment,
  `reference` varchar(20) not null,
  `customer_id` int unsigned not null,
  `status_id` smallint not null default 1,
  `created_at` datetime not null,
  primary key (`id`),
  unique key `orders_reference_uniq` (`reference`),
  key `idx_orders_customer` (`customer_id`),
  constraint `fk_orders_customer` foreign key (`customer_id`)
    references `customers` (`id`)
);
```

An ordinary `sql` buffer. Search it, yank from it, send it to a colleague.

| Key | Effect |
|---|---|
| `gr` | reload from the server |
| `gD` | diff this against the server's version |
| `q` | close |

## The diff

`gD` opens the server's current definition beside the buffer in Neovim's own
diff mode, so `]c`, `[c` and `do` work. Useful after someone else has been in
there.

## Comparing two schemas

`:DBClientSchemaDiff` compares the same object across two connections, dev
against production, as a diff rather than a report. It also answers "what did
that migration actually change".
