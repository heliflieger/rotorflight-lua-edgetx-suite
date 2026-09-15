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

function M.show(ctx)
  local title = (ctx and ctx.title) or "Unsupported MSP API"
  local message = (ctx and ctx.message) or ""

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

  -- Deduplicate: prefer an API-version-based key so different localized
  -- titles/messages for the same API version don't show twice. Keep a set
  -- of shown keys in `_G.rfsuite._msp_unsupported_dialog_shown_keys`.
  local title_msg_key = tostring(title) .. "\n" .. tostring(message)
  local version_key = nil
  do
    if ctx and type(ctx.version) == "string" and ctx.version ~= "" then
      version_key = "msp_unsupported_version:" .. tostring(ctx.version)
    else
      local found = string.match(message or "", "(%d+%.%d+)")
      if found and found ~= "" then
        version_key = "msp_unsupported_version:" .. tostring(found)
      end
    end
  end

  local g = _G or _ENV
  local root = nil
  if type(g) == "table" then
    if type(g.rfsuite) ~= "table" then g.rfsuite = {} end
    root = g.rfsuite
    if type(root._msp_unsupported_dialog_shown_keys) ~= "table" then root._msp_unsupported_dialog_shown_keys = {} end
    local keys = root._msp_unsupported_dialog_shown_keys
    if version_key and keys[version_key] then
      return true
    end
    if keys[title_msg_key] then
      return true
    end
  end
  -- Do not call LVGL APIs here (some targets lack `message`/`alert`).
  -- Log the condition, mark the title/message as shown to dedupe,
  -- and invoke the provided fallback if present.
  if Log and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.ui.msp_unsupported_dialog", "unsupported MSP API: " .. tostring(title_msg_key), "debug") end
  if root then
    local keys = root._msp_unsupported_dialog_shown_keys or {}
    keys[title_msg_key] = true
    if version_key then keys[version_key] = true end
    root._msp_unsupported_dialog_shown_keys = keys
  end
  if type(ctx and ctx.onFallback) == "function" then
    pcall(ctx.onFallback, title, message)
  end
  return true
end

return M
