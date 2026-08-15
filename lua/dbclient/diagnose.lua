--- Why a connection failed, layer by layer.
---
--- `Connection refused` is the least useful true statement a program can make.
--- Refused by what? The host resolved, or it did not. Something is listening on
--- that port, or nothing is. TLS was required, or it was not. The password was
--- wrong, or the user is simply not allowed in from this address. Every one of
--- those has a different fix and every client reports all of them the same way.
---
--- So instead of guessing, each layer is tested in order and the first one that
--- fails is named. The test costs a DNS lookup and a TCP connect — under a
--- second — and it runs only after a connection has already failed, so nothing
--- pays for it in the normal case.
---
--- The layers, in the order a connection actually crosses them:
---
---   1. is the host a name we can resolve, or an address
---   2. is anything accepting connections on that port
---   3. does the server speak the protocol we expect
---   4. are the credentials accepted
---   5. does the database exist and can this user see it
---
--- Everything here is read-only and touches nothing but the connection under
--- test.

local M = {}

--- One step of the diagnosis.
---@class DiagnosisStep
---@field layer string
---@field ok boolean
---@field detail string
---@field remedy string|nil

-- ---------------------------------------------------------------------------
-- The individual probes
-- ---------------------------------------------------------------------------

--- Is the host something we can reach at all?
---@param host string
---@return DiagnosisStep
function M.check_host(host)
  if host == nil or host == "" then
    return {
      layer = "host",
      ok = false,
      detail = "no host in the connection",
      remedy = "set `host`, or `path` for SQLite",
    }
  end

  -- An address needs no resolving.
  if host:match("^%d+%.%d+%.%d+%.%d+$") or host:find(":", 1, true) then
    return { layer = "host", ok = true, detail = host .. " is an address" }
  end

  local resolved = vim.uv.getaddrinfo(host, nil, { family = "inet" })
  if resolved and resolved[1] then
    return {
      layer = "host",
      ok = true,
      detail = ("%s resolves to %s"):format(host, resolved[1].addr),
    }
  end

  return {
    layer = "host",
    ok = false,
    detail = ("%s does not resolve"):format(host),
    remedy = "check the spelling, your DNS, or whether the container is running "
      .. "under a different name than the compose service",
  }
end

--- Is anything listening?
---
--- Distinguishes the three outcomes that matter and that a single error string
--- conflates: refused (nothing there), timed out (something is dropping the
--- packets), and accepted.
---@param host string
---@param port integer
---@param timeout_ms integer|nil
---@return DiagnosisStep
function M.check_port(host, port, timeout_ms)
  timeout_ms = timeout_ms or 2000
  if not port or port == 0 then
    return { layer = "port", ok = false, detail = "no port in the connection" }
  end

  local socket = vim.uv.new_tcp()
  local outcome, finished = nil, false

  socket:connect(host, port, function(err)
    outcome = err
    finished = true
    pcall(function()
      socket:close()
    end)
  end)

  local completed = vim.wait(timeout_ms, function()
    return finished
  end, 20)

  if not completed then
    pcall(function()
      socket:close()
    end)
    return {
      layer = "port",
      ok = false,
      detail = ("nothing answered on %s:%d within %dms"):format(host, port, timeout_ms),
      remedy = "a firewall is usually what drops packets rather than refusing "
        .. "them; a refused connection would have come back immediately",
    }
  end

  if outcome then
    local message = tostring(outcome)
    local remedy
    if message:find("ECONNREFUSED") then
      remedy = "nothing is listening there. Check the port, and whether the "
        .. "server is running — `docker compose ps` if it is a container"
    elseif message:find("EHOSTUNREACH") or message:find("ENETUNREACH") then
      remedy = "no route to that host from here"
    end
    return {
      layer = "port",
      ok = false,
      detail = ("%s:%d — %s"):format(host, port, message),
      remedy = remedy,
    }
  end

  return { layer = "port", ok = true, detail = ("%s:%d is accepting connections"):format(host, port) }
end

--- Read what the classified error says about the layers past the socket.
---
--- These cannot be probed independently — trying costs a second connection and
--- a second failed login, which on some servers counts towards a lockout — so
--- they are read off the failure that already happened.
---@param err table  a normalised error
---@param spec table
---@return DiagnosisStep[]
function M.layers_from_error(err, spec)
  local steps = {}

  if err.kind == "authentication" then
    table.insert(steps, {
      layer = "credentials",
      ok = false,
      detail = ("the server refused user `%s`"):format(spec.user or "?"),
      remedy = "MySQL grants are per host as well as per user, so the same "
        .. "password can work from the container and fail over TCP. Check "
        .. "`select user, host from mysql.user`, or `pg_hba.conf` on PostgreSQL",
    })
    return steps
  end

  if err.kind == "undefined_database" then
    table.insert(steps, { layer = "credentials", ok = true, detail = "the server accepted the login" })
    table.insert(steps, {
      layer = "database",
      ok = false,
      detail = ("no database named `%s`"):format(spec.database or err.schema or "?"),
      remedy = "leave `database` unset to connect to the server's default and "
        .. "list what is actually there",
    })
    return steps
  end

  if err.kind == "too_many_connections" then
    table.insert(steps, {
      layer = "credentials",
      ok = false,
      detail = "the server has no connection slots left",
      remedy = "something is leaking connections; `<leader>da` lists them",
    })
    return steps
  end

  local message = (err.message or ""):lower()
  if message:find("ssl") or message:find("tls") then
    table.insert(steps, {
      layer = "encryption",
      ok = false,
      detail = err.message,
      remedy = "the server requires TLS, or offers one this client will not accept",
    })
    return steps
  end

  return steps
end

-- ---------------------------------------------------------------------------
-- Running it
-- ---------------------------------------------------------------------------

--- Diagnose a failed connection.
---
--- Stops at the first failing layer: once the port is closed, nothing can be
--- said about the credentials, and saying it anyway would be a guess.
---@param opts { spec: table, error?: table }
---@return DiagnosisStep[]
function M.run(opts)
  local spec = opts.spec or {}
  local steps = {}

  local adapter = tostring(spec.adapter or ""):lower()
  if adapter:find("sqlite") then
    local path = spec.path or ""
    local readable = path ~= "" and vim.fn.filereadable(vim.fn.expand(path)) == 1
    table.insert(steps, {
      layer = "file",
      ok = readable,
      detail = readable and (path .. " exists") or (path .. " is not a readable file"),
      remedy = not readable
          and "SQLite creates a database on first write, so a missing file is "
            .. "only a problem for a read-only connection"
        or nil,
    })
    return steps
  end

  local host = spec.host or "127.0.0.1"
  local port = spec.port
      or ({ postgres = 5432, postgresql = 5432, pg = 5432, mariadb = 3306, mysql = 3306 })[adapter]
    or 0

  local host_step = M.check_host(host)
  table.insert(steps, host_step)
  if not host_step.ok then
    return steps
  end

  local port_step = M.check_port(host, port)
  table.insert(steps, port_step)
  if not port_step.ok then
    return steps
  end

  -- The socket is fine, so whatever went wrong happened after it.
  if opts.error then
    vim.list_extend(steps, M.layers_from_error(opts.error, spec))
  end

  if #steps == 2 then
    table.insert(steps, {
      layer = "handshake",
      ok = false,
      detail = opts.error and opts.error.message or "the server refused the connection",
      remedy = "the socket opened, so the server is there and rejected us after "
        .. "that — the adapter may be wrong for this server",
    })
  end

  return steps
end

--- Render a diagnosis.
---@param steps DiagnosisStep[]
---@param spec table
---@param name string
---@return string[] lines, table[] marks
function M.render(steps, spec, name)
  local lines = {
    ("could not connect to `%s`"):format(name),
    "",
  }
  local marks = { { line = 0, group = "DBClientSeverityError" } }

  for _, step in ipairs(steps) do
    local mark = step.ok and "ok  " or "✗   "
    table.insert(lines, ("  %s%-12s %s"):format(mark, step.layer, step.detail))
    table.insert(marks, {
      line = #lines - 1,
      group = step.ok and "DBClientSeverityOk" or "DBClientSeverityError",
    })
    if step.remedy then
      for _, wrapped in ipairs(vim.split(step.remedy, "\n")) do
        -- Simple wrap at 72, which is where the panel is comfortable.
        local current = "        "
        for word in wrapped:gmatch("%S+") do
          if #current + #word + 1 > 76 and current ~= "        " then
            table.insert(lines, current)
            table.insert(marks, { line = #lines - 1, group = "DBClientHelpText" })
            current = "        " .. word
          else
            current = current == "        " and (current .. word) or (current .. " " .. word)
          end
        end
        if current ~= "        " then
          table.insert(lines, current)
          table.insert(marks, { line = #lines - 1, group = "DBClientHelpText" })
        end
      end
    end
  end

  local _ = spec
  return lines, marks
end

--- Diagnose and show, as the follow-up to a failed connection.
---@param opts { name: string, spec: table, error?: table }
function M.show(opts)
  local steps = M.run(opts)
  local lines, marks = M.render(steps, opts.spec, opts.name)

  local buffer = require("dbclient.ui.buffer")
  local bufnr = buffer.scratch("dbclient://connection", { filetype = "dbclient-diagnosis" })
  buffer.set_lines(bufnr, lines)
  require("dbclient.ui.highlights").lines(bufnr, marks)

  local previous = vim.api.nvim_get_current_win()
  vim.cmd(("botright %dsplit"):format(math.min(#lines + 1, 16)))
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.wo[winid].number = false
  vim.wo[winid].signcolumn = "no"
  require("dbclient.ui.window").close_keys(bufnr, winid)
  if vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end
end

return M
