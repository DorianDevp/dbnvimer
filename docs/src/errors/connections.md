# Connections that will not open

*Connection refused* is the least useful true statement a program can make.
Refused by what?

```text
could not connect to `staging`

  ok  host         127.0.0.1 is an address
  ok  port         127.0.0.1:3306 is accepting connections
  ✗   credentials  the server refused user `app`
        MySQL grants are per host as well as per user, so the same password
        can work from the container and fail over TCP. Check
        `select user, host from mysql.user`, or `pg_hba.conf` on PostgreSQL.
```

Each layer is tested in order and the first one that fails is named — and only
that one, because once a hostname does not resolve nothing true can be said
about the port.

## The layers

| Layer | Tested by |
|---|---|
| host | resolving the name, or recognising an address |
| port | a TCP connect, distinguishing refused from timed out |
| credentials | read off the classified failure |
| database | read off the classified failure |
| encryption | read off the classified failure |

Refused and timed out are different answers: something refusing you
immediately is a closed port, and something dropping your packets is usually a
firewall. Conflating them is why this normally takes twenty minutes.

## For SQLite

A file, not a socket. It checks the path is readable, and notes that a missing
file is only a problem for a read-only connection — SQLite creates the
database on first write.

## Cost

Only run *after* a connection has already failed, so nothing pays for it in
the normal case. A DNS lookup and a TCP connect, under a second.
