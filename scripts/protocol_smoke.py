#!/usr/bin/env python3
"""Drive the dbclient-core daemon over stdio and check the protocol end to end.

Usage:
    python3 scripts/protocol_smoke.py [path-to-core] [path-to-sqlite-db]

Creates its own throwaway SQLite database when no path is given. Exits non-zero
on the first failed expectation, so it works as a CI smoke test.
"""

import json
import os
import sqlite3
import subprocess
import sys
import tempfile

FAILURES = []


def check(label, condition, detail=""):
    status = "ok  " if condition else "FAIL"
    print(f"{status} {label}" + (f"  -- {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(label)


class Core:
    def __init__(self, binary):
        self.proc = subprocess.Popen(
            [binary, "serve"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.next_id = 0
        ready = json.loads(self.proc.stdout.readline())
        assert ready.get("event") == "ready", ready
        self.version = ready["data"]["version"]

    def call(self, op, session=None, **params):
        self.next_id += 1
        frame = {"id": self.next_id, "op": op, "params": params}
        if session:
            frame["session"] = session
        self.proc.stdin.write(json.dumps(frame) + "\n")
        self.proc.stdin.flush()
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("core closed the connection")
            message = json.loads(line)
            if message.get("id") == self.next_id:
                return message
            # Ignore unsolicited events.

    def data(self, op, session=None, **params):
        message = self.call(op, session, **params)
        if not message.get("ok"):
            raise RuntimeError(f"{op} failed: {message.get('error')}")
        return message["data"]

    def close(self):
        try:
            self.call("shutdown")
        except Exception:
            pass
        self.proc.terminate()


def make_db(path):
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        create table users (
            id integer primary key,
            name text not null,
            note text,
            city text
        );
        create table orders (
            id integer primary key,
            user_id integer references users(id),
            total real
        );
        """
    )
    conn.executemany(
        "insert into users values (?,?,?,?)",
        [(1, "Łódź", "ma\nnową linię", "PL"), (2, "NULL", None, "DE"), (3, "Kraków", "ok", "PL")],
    )
    conn.executemany(
        "insert into orders values (?,?,?)", [(10, 1, 99.5), (11, 1, 10.0), (12, 3, 5.25)]
    )
    conn.commit()
    conn.close()


def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else "rust/dbclient-core/target/release/dbclient-core"
    if len(sys.argv) > 2:
        db_path = sys.argv[2]
    else:
        db_path = os.path.join(tempfile.mkdtemp(prefix="dbclient-smoke-"), "demo.db")
        make_db(db_path)

    core = Core(binary)
    print(f"core {core.version}, database {db_path}\n")

    session = core.data("open-session", connection={"adapter": "sqlite", "path": db_path})
    sid = session["session"]
    check("open-session returns an id", bool(sid), session)
    check("backend info names the adapter", session["info"]["adapter"] == "sqlite")

    schemas = core.data("schemas", sid)
    check("schemas lists main", any(s["name"] == "main" for s in schemas), schemas)

    tables = core.data("tables", sid, schema="main")
    names = sorted(t["name"] for t in tables)
    check("tables lists both tables", names == ["orders", "users"], names)

    columns = core.data("columns", sid, schema="main", table="users")
    check("columns marks the primary key", columns[0]["key"] == "PRI", columns[0])
    check("columns carry a render class", columns[1]["class"] == "text", columns[1])

    preview = core.data("preview", sid, schema="main", table="users")
    check("preview orders by primary key", preview["rows"][0][0] == "1")
    check("SQL NULL arrives as JSON null", preview["rows"][1][2] is None, preview["rows"][1])
    check("the literal string NULL survives", preview["rows"][1][1] == "NULL")
    check("newlines inside values are preserved", "\n" in preview["rows"][0][2])
    check("utf-8 values are intact", preview["rows"][0][1] == "Łódź")

    limited = core.data("preview", sid, schema="main", table="users", limit=2)
    check("truncation is reported", limited["truncated"] and len(limited["rows"]) == 2)

    sorted_desc = core.data(
        "preview", sid, schema="main", table="users", order=[{"column": "id", "dir": "desc"}]
    )
    check("explicit sort is honoured", sorted_desc["rows"][0][0] == "3")

    filtered = core.data("preview", sid, schema="main", table="users", filter="city = 'PL'")
    check("filters apply", len(filtered["rows"]) == 2, filtered["rows"])

    bad_filter = core.call("preview", sid, schema="main", table="users", filter="1=1; drop table users")
    check("multi-statement filters are rejected", not bad_filter["ok"], bad_filter)

    total = core.data("count", sid, schema="main", table="users")
    check("count returns the row total", total["count"] == 3, total)

    refs = core.data("referencing-keys", sid, schema="main", table="users")
    check("reverse foreign keys are found", any(r["table"] == "orders" for r in refs), refs)

    fks = core.data("foreign-keys", sid, schema="main", table="orders")
    check("forward foreign keys are found", fks and fks[0]["ref_table"] == "users", fks)

    stats = core.data("column-stats", sid, schema="main", table="users", column="city")
    check("column stats count distinct values", stats["distinct"] == "2", stats)
    check("column stats list top values", len(stats["top"]) == 2, stats["top"])

    ddl = core.data("ddl", sid, schema="main", name="users", kind="table")
    check("ddl round-trips the table", "create table users" in ddl["ddl"].lower(), ddl)

    diagnostics = core.data("lint-sql", sql="delete from users;")["diagnostics"]
    check("linter flags unfiltered deletes", diagnostics[0]["code"] == "unfiltered-write", diagnostics)

    split = core.data("split-sql", sql="select ';' as a; -- x\nselect 2;")["statements"]
    check("splitter ignores semicolons in strings", len(split) == 2, split)

    core.data("begin", sid)
    change = {
        "op": "update",
        "schema": "main",
        "table": "users",
        "set": {"city": "CZ"},
        "pk": {"id": "1"},
        "expect": {"city": "PL"},
    }
    applied = core.data("apply-changes", sid, changes=[change])
    check("staged update applies", applied["affected_rows"] == 1, applied)
    core.data("rollback", sid)
    after = core.data("preview", sid, schema="main", table="users", filter="id = 1")
    check("rollback restores the value", after["rows"][0][3] == "PL", after["rows"][0])

    stale = dict(change, expect={"city": "ZZ"})
    conflict = core.call("apply-changes", sid, changes=[stale])
    check("stale expectations are rejected", not conflict["ok"], conflict)

    explain = core.data("explain", sid, sql="select * from users where id = 1")
    check("explain returns a plan", "format" in explain, explain)

    read_only = core.data(
        "open-session", connection={"adapter": "sqlite", "path": db_path, "access": "read"}
    )
    ro = read_only["session"]
    check("read-only sessions allow selects", core.call("query", ro, sql="select 1")["ok"])
    check(
        "read-only sessions refuse writes",
        not core.call("query", ro, sql="delete from users")["ok"],
    )
    core.data("close-session", ro)

    listed = core.data("sessions")["sessions"]
    check("session registry tracks open sessions", len(listed) == 1, listed)

    core.data("close-session", sid)
    core.close()

    print()
    if FAILURES:
        print(f"{len(FAILURES)} check(s) failed: {', '.join(FAILURES)}")
        return 1
    print("all protocol checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
