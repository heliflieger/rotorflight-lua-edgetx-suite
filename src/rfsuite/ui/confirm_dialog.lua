local M = {}

local Log = nil

local unpack_fn = table.unpack or unpack
local function safeCall(fn, ...)
  if type(fn) ~= "function" then return false, "not a function" end
  if type(debug) == "table" and type(debug.traceback) == "function" and type(xpcall) == "function" then
    local args = { ... }
    local function wrapped()
      return fn(unpack_fn(args))
    end
    local ok, res = xpcall(wrapped, debug.traceback)
    return ok, res
  end
  return pcall(fn, ...)
end

-- Show a confirm dialog that behaves like legacy `lvgl.confirm` when possible.
-- ctx: { title=string, message=string, onConfirm=function, onCancel=function, onFallback=function }
-- Returns true if a UI was shown or fallback executed, false otherwise.
function M.show(ctx)
  local title = (ctx and ctx.title) or "Confirm"
  local message = (ctx and ctx.message) or ""
  local onConfirm = ctx and ctx.onConfirm
  local onCancel = ctx and ctx.onCancel
  local onFallback = ctx and ctx.onFallback

  if Log == nil then
    local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/log.lua", "t")
    if type(chunk) == "function" then
      local ok, mod = pcall(chunk)
      if ok and type(mod) == "table" and type(mod.emit) == "function" then
        Log = mod
      else
        Log = false
      end
    else
      Log = false
    end
  end

  if type(Log) == "table" and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.ui.confirm_dialog", "lvgl types: message=" .. tostring(type(lvgl and lvgl.message)), "debug") end

  local handled = false
  local function doConfirm()
    if handled then return end
    handled = true
    if type(onConfirm) == "function" then pcall(onConfirm) end
  end
  local function doCancel()
    if handled then return end
    handled = true
    if type(onCancel) == "function" then pcall(onCancel) end
  end

  -- Prefer `lvgl.confirm` when available; avoid noisy lvgl.message/dialog attempts.
  if lvgl and type(lvgl.confirm) == "function" then
    local ok, res = safeCall(function()
      return lvgl.confirm({ title = title, message = message, confirm = doConfirm, cancel = doCancel })
    end)
    if Log and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.ui.confirm_dialog", "lvgl.confirm attempt ok=" .. tostring(ok) .. ", res=" .. tostring(res), "debug") end

    if ok and res == true then
      doConfirm()
      return true
    end
    if ok and res == false then
      doCancel()
      return true
    end
    -- lvgl.confirm is asynchronous: the binding registers the callbacks and returns
    -- nothing, so a nil result means the dialog is up, not that it could not be shown.
    -- The answer arrives through doConfirm/doCancel.
    if ok then
      return true
    end
  end

  if type(onFallback) == "function" then
    pcall(onFallback, title, message)
    return true
  end

  return false
end

return M
