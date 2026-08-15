--- Comparing two readings of a counter that only ever goes up.
---
--- The arithmetic is the whole feature. `pg_stat_statements` and
--- `performance_schema` both report totals since the server started, so the
--- average they publish is the average over the process's entire life — which
--- on a server that has been up for a month says nothing about this week. The
--- number that matters is the one over the window between two readings, and
--- getting it wrong means reporting either nothing or everything.

local t = require("tests.init")
local statements = require("dbclient.statements")

--- One row of a digest table.
local function row(digest, calls, total_ms, text)
  return {
    digest = digest,
    text = text or ("select … " .. digest),
    calls = calls,
    total_ms = total_ms,
    avg_ms = calls > 0 and (total_ms / calls) or 0,
  }
end

t.describe("comparing two readings", {
  ["measures the window, not the lifetime"] = function()
    -- 100 calls averaging 1 ms, then 100 more averaging 20 ms. The published
    -- average is 10.5 ms — half the truth — while the window says 20.
    local before = { row("a", 100, 100) }
    local after = { row("a", 200, 2100) }

    local diff = statements.compare(before, after)
    t.eq(#diff.slower, 1)
    local found = diff.slower[1]
    t.eq(found.window_calls, 100)
    t.eq(found.window_avg_ms, 20)
    t.eq(found.was_avg_ms, 1)
    t.eq(found.ratio, 20)
  end,

  ["reports what got faster too"] = function()
    local diff = statements.compare({ row("a", 100, 2000) }, { row("a", 200, 2100) })
    t.eq(#diff.faster, 1)
    t.eq(#diff.slower, 0)
    t.ok(diff.faster[1].ratio < 1)
  end,

  ["says nothing about a statement that barely moved"] = function()
    local diff = statements.compare({ row("a", 100, 100) }, { row("a", 200, 220) })
    t.eq(diff.slower, {})
    t.eq(diff.faster, {})
  end,

  ["ignores a statement with too few calls to mean anything"] = function()
    -- One call that happened to be slow is noise, not a regression.
    local diff = statements.compare({ row("a", 100, 100) }, { row("a", 101, 1100) })
    t.eq(diff.slower, {})
  end,

  ["notices a statement that was not there before"] = function()
    local diff = statements.compare({ row("a", 100, 100) }, { row("a", 100, 100), row("b", 50, 900) })
    t.eq(#diff.appeared, 1)
    t.eq(diff.appeared[1].digest, "b")
  end,

  ["says nothing when the counters went backwards"] = function()
    -- The server restarted or the view was reset. There is nothing to compare,
    -- and treating the smaller numbers as a change would report the entire
    -- workload as having got faster.
    local diff = statements.compare({ row("a", 500, 5000) }, { row("a", 10, 100) })
    t.eq(diff.slower, {})
    t.eq(diff.faster, {})
    t.eq(diff.appeared, {}, "and not as new, either")
  end,

  ["ranks by how much time the change actually costs"] = function()
    -- Ten times slower on a statement called twice matters less than twice as
    -- slow on one called ten thousand times.
    local before = { row("rare", 100, 100), row("hot", 10000, 10000) }
    local after = { row("rare", 110, 200), row("hot", 20000, 40000) }

    local diff = statements.compare(before, after)
    t.eq(#diff.slower, 2)
    t.eq(diff.slower[1].digest, "hot", "the one that costs more seconds comes first")
  end,

  ["honours an explicit threshold"] = function()
    local before = { row("a", 100, 100) }
    local after = { row("a", 200, 260) }
    t.eq(statements.compare(before, after, { threshold = 2.0 }).slower, {})
    t.eq(#statements.compare(before, after, { threshold = 1.2 }).slower, 1)
  end,
})

t.describe("reading the numbers", {
  ["scales a duration to something sayable"] = function()
    t.eq(statements.duration(0.42), "0.42 ms")
    t.eq(statements.duration(41), "41 ms")
    t.eq(statements.duration(1500), "1.5 s")
    t.eq(statements.duration(90000), "1.5 min")
    t.eq(statements.duration(5400000), "1.5 h")
  end,

  ["groups a call count"] = function()
    t.eq(statements.thousands(7), "7")
    t.eq(statements.thousands(1234), "1 234")
    t.eq(statements.thousands(84122), "84 122")
    t.eq(statements.thousands(1234567), "1 234 567")
  end,
})

t.describe("rendering", {
  ["ranks by total time, not by average"] = function()
    -- The whole point: four milliseconds eighty thousand times is the problem,
    -- and no slow-query threshold ever catches it.
    local lines = statements.render({
      row("hot", 80000, 320000, "select * from inquiry where user_id = ?"),
      row("rare", 3, 2700, "select * from report"),
    }, { source = "performance_schema", connection = "prod", width = 100 })

    local text = table.concat(lines, "\n")
    t.matches(text, "performance_schema")
    t.matches(text, "80 000")
    -- The hot one is listed first because the caller ordered it so; what is
    -- asserted here is that both survive rendering with readable numbers.
    t.matches(text, "5.3 min")
    t.matches(text, "2.7 s")
  end,

  ["marks a statement that reads far more than it returns"] = function()
    local hot = row("a", 10, 100, "select * from t")
    hot.rows_sent = 10
    hot.rows_examined = 5000000
    local _, marks = statements.render({ hot }, { source = "x", connection = "c" })

    local flagged = false
    for _, mark in ipairs(marks) do
      if mark.group == "DBClientPlanHot" then
        flagged = true
      end
    end
    t.ok(flagged, "the shape of a missing index is worth seeing from across the room")
  end,

  ["renders a comparison with the direction of travel"] = function()
    local diff = statements.compare({ row("a", 100, 100) }, { row("a", 200, 2100) })
    local lines = statements.render_comparison(diff, {
      before = { taken_at = 1786000000 },
      after = {},
      connection = "prod",
      width = 100,
    })
    local text = table.concat(lines, "\n")
    t.matches(text, "1 slower")
    t.matches(text, "20%.0×")
    -- 100 calls in 100 ms before, 100 more in 2000 ms after.
    t.matches(text, "1 ms")
    t.matches(text, "20 ms")
  end,

  ["says so when nothing moved"] = function()
    local text = table.concat(
      statements.render_comparison(
        { slower = {}, faster = {}, appeared = {} },
        { before = { taken_at = 0 }, after = {}, connection = "prod" }
      ),
      "\n"
    )
    t.matches(text, "nothing moved by enough to mention")
  end,

  ["explains a server that is collecting nothing"] = function()
    local lines = statements.render_unavailable({
      available = false,
      reason = "performance_schema is off",
      remedy = { "Add `performance_schema = ON` to my.cnf and restart." },
    }, "vw-db")

    local text = table.concat(lines, "\n")
    -- An empty table would be a lie by omission: the server is not slow, it is
    -- simply not counting.
    t.matches(text, "vw%-db is not keeping statement statistics")
    t.matches(text, "performance_schema is off")
    t.matches(text, "my%.cnf")
    t.matches(text, "DBClient itself ran", "and what is available meanwhile")
  end,
})
