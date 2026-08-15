--- Async JSON-RPC client for the `dbclient-core` daemon.
---
--- One long-lived process serves every connection. Requests never block the
--- editor: results arrive on the event loop and are delivered either to a
--- callback or, more commonly, by resuming the coroutine that asked for them.
---
--- Typical use:
--- <pre>lua
---   client.async(function()
---     local schemas = client.call("schemas", {}, session)
---     -- ...runs after the reply arrives, but reads like straight-line code
---   end)
--- </pre>

local config = require("dbclient.config")

local M = {
  handle = nil,
  ready = false,
  next_id = 0,
  pending = {},
  stdout = "",
  stderr = {},
  version = nil,
  protocol = nil,
  listeners = {},
  ---@type table<thread, fun(...)>
  steppers = setmetatable({}, { __mode = "k" }),
}

--- Protocol version this Lua front end speaks.
M.EXPECTED_PROTOCOL = 1

local function notify(message, level)
  vim.schedule(function()
    vim.notify("DBClient: " .. message, level or vim.log.levels.ERROR)
  end)
end

--- Fail every in-flight request, used when the daemon dies.
local function fail_pending(reason)
  local pending = M.pending
  M.pending = {}
  for _, entry in pairs(pending) do
    entry.callback(reason, nil)
  end
end

local function emit(event, payload)
  for _, listener in ipairs(M.listeners[event] or {}) do
    pcall(listener, payload)
  end
end

--- Subscribe to a daemon event (`ready`, `session-open`, `exit`).
---@param event string
---@param callback fun(payload: table)
function M.on(event, callback)
  M.listeners[event] = M.listeners[event] or {}
  table.insert(M.listeners[event], callback)
end

local function handle_frame(frame)
  if frame.event then
    if frame.event == "ready" then
      M.ready = true
      M.version = frame.data and frame.data.version
      M.protocol = frame.data and frame.data.protocol
      if M.protocol and M.protocol ~= M.EXPECTED_PROTOCOL then
        notify(
          ("core protocol %s does not match the plugin's %s; rebuild dbclient-core")
            :format(M.protocol, M.EXPECTED_PROTOCOL),
          vim.log.levels.WARN
        )
      end
    end
    emit(frame.event, frame.data)
    return
  end

  local entry = M.pending[frame.id]
  if not entry then
    return
  end
  M.pending[frame.id] = nil

  if frame.ok then
    entry.callback(nil, frame.data)
  else
    -- The structured form travels beside the message rather than instead of
    -- it, so every existing handler keeps working on a plain string while
    -- anything that wants the position, the constraint or the offending value
    -- can ask for it.
    entry.callback(frame.error or "unknown core error", nil, frame.detail)
  end
end

local function consume(chunk)
  M.stdout = M.stdout .. chunk
  while true do
    local newline = M.stdout:find("\n", 1, true)
    if not newline then
      break
    end
    local line = M.stdout:sub(1, newline - 1)
    M.stdout = M.stdout:sub(newline + 1)
    if line ~= "" then
      local ok, frame = pcall(vim.json.decode, line)
      if ok and type(frame) == "table" then
        handle_frame(frame)
      end
    end
  end
end

--- Start the daemon if it is not already running.
---@return boolean started
function M.ensure()
  if M.handle and not M.handle:is_closing() then
    return true
  end

  local command = config.get().core.command
  if vim.fn.executable(command) ~= 1 then
    notify(("core binary not found: %s (run :checkhealth dbclient)"):format(command))
    return false
  end

  M.stdout = ""
  M.stderr = {}
  M.ready = false

  local ok, handle = pcall(vim.system, { command, "serve" }, {
    stdin = true,
    stdout = function(err, data)
      if err or not data then
        return
      end
      vim.schedule(function()
        consume(data)
      end)
    end,
    stderr = function(err, data)
      if err or not data then
        return
      end
      table.insert(M.stderr, data)
    end,
  }, function(result)
    vim.schedule(function()
      M.handle = nil
      M.ready = false
      local detail = table.concat(M.stderr, "")
      fail_pending(("core exited with code %s%s"):format(
        result.code,
        detail ~= "" and (": " .. detail) or ""
      ))
      emit("exit", result)
    end)
  end)

  if not ok then
    notify("failed to start core: " .. tostring(handle))
    return false
  end

  M.handle = handle
  return true
end

--- Stop the daemon and drop every session.
function M.stop()
  if not M.handle then
    return
  end
  local handle = M.handle
  M.handle = nil
  M.ready = false
  pcall(function()
    handle:write(vim.json.encode({ id = 0, op = "shutdown" }) .. "\n")
  end)
  vim.defer_fn(function()
    pcall(function()
      handle:kill(15)
    end)
  end, 200)
end

--- Send a request. The callback receives `(err, data)`.
---@param op string
---@param params table|nil
---@param session string|nil
---@param callback fun(err: string|nil, data: any)
---@return integer|nil id
function M.request(op, params, session, callback)
  if not M.ensure() then
    callback("core is not running", nil)
    return nil
  end

  M.next_id = M.next_id + 1
  local id = M.next_id
  local frame = { id = id, op = op, params = params or vim.empty_dict() }
  if session then
    frame.session = session
  end

  M.pending[id] = { op = op, callback = callback, started = vim.uv.hrtime() }

  local ok, err = pcall(function()
    M.handle:write(vim.json.encode(frame) .. "\n")
  end)
  if not ok then
    M.pending[id] = nil
    callback("failed to write to core: " .. tostring(err), nil)
    return nil
  end

  return id
end

--- The structured form of the error `M.call` is about to raise.
---
--- Errors stay strings because every call site treats them as one, so the
--- structure rides alongside in a slot rather than inside the value. That is
--- safe because it is written and read within a single coroutine resume: the
--- `error()` in `M.call` unwinds straight into the handler below with nothing
--- able to run in between.
M.last_error = nil

--- Run `fn` as a coroutine in which `M.call` behaves like a blocking call.
---@param fn fun()
---@param on_error? fun(err: string, detail: table|nil)
function M.async(fn, on_error)
  local co = coroutine.create(fn)
  local function step(...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then
      local message = type(err) == "string" and err or vim.inspect(err)
      local detail = M.last_error
      M.last_error = nil
      if detail then
        require("dbclient.errors").record(message, detail)
      end
      if on_error then
        on_error(message, detail)
      else
        notify(message)
      end
    end
  end
  M.steppers[co] = step
  step()
end

--- Issue a request from inside `M.async`, yielding until the reply arrives.
---@param op string
---@param params table|nil
---@param session string|nil
---@return any data
function M.call(op, params, session)
  local co = coroutine.running()
  local step = co and M.steppers[co]
  if not step then
    error("dbclient: client.call must run inside client.async", 0)
  end

  M.request(op, params, session, function(err, data, detail)
    step(err, data, detail)
  end)

  local err, data, detail = coroutine.yield()
  if err then
    M.last_error = detail
    error(err, 0)
  end
  M.last_error = nil
  return data
end

--- Issue a request and ignore the reply.
function M.notify_op(op, params, session)
  M.request(op, params, session, function() end)
end

--- Blocking request, used by `:checkhealth` and tests only.
---@param op string
---@param params table|nil
---@param session string|nil
---@param timeout_ms integer|nil
---@return string|nil err, any data
function M.await(op, params, session, timeout_ms)
  local done, result_err, result_data = false, nil, nil
  M.request(op, params, session, function(err, data)
    result_err, result_data, done = err, data, true
  end)
  local ok = vim.wait(timeout_ms or 5000, function()
    return done
  end, 10)
  if not ok then
    return "timed out waiting for core", nil
  end
  return result_err, result_data
end

--- Number of requests currently in flight, for the statusline spinner.
---@return integer
function M.in_flight()
  return vim.tbl_count(M.pending)
end

--- Ops that are currently waiting on the core, newest first.
---@return string[]
function M.in_flight_ops()
  local ops = {}
  for _, entry in pairs(M.pending) do
    table.insert(ops, entry.op)
  end
  return ops
end

return M
