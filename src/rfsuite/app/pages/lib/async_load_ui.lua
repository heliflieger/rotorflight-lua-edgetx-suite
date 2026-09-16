local M = {}

-- Reached through the global the log module publishes rather than loaded here: this is a leaf
-- helper with no dependencies of its own and it should keep none. Absent logger, absent lines.
--
-- Which page a load belongs to is not known in this file -- the state table is built by begin()
-- and carries no id -- so these lines are read next to the `page ... -> ...` line that
-- ui/home.lua writes immediately before the page starts loading.
local function logf(level, fmt, ...)
  local Log = type(_G) == "table" and _G.rfsuite and _G.rfsuite.Log
  if type(Log) == "table" and type(Log.emitf) == "function" then
    pcall(Log.emitf, "rfsuite.page", level, fmt, ...)
  end
end

local function clamp01(v)
  local n = tonumber(v) or 0
  if n < 0 then return 0 end
  if n > 1 then return 1 end
  return n
end

function M.begin(state, nowSec, totalSteps, showOverlay)
  state.loading = true
  state.showLoadingOverlay = showOverlay == true
  state.loadingStartedAt = tonumber(nowSec) or 0
  state.done = 0
  state.total = math.max(0, tonumber(totalSteps) or 0)
  state.progress = 0
  state.errorMessage = nil
  state.errorDialogShown = nil
  logf("debug", "load begin steps=%d overlay=%s", state.total, tostring(state.showLoadingOverlay))
end

function M.stepDone(state)
  state.done = (tonumber(state.done) or 0) + 1
  local total = tonumber(state.total) or 0
  if total > 0 then
    state.progress = clamp01(state.done / total)
  else
    state.progress = 1
  end

  if total > 0 and state.done >= total then
    state.loading = false
    state.showLoadingOverlay = false
    logf("debug", "load done steps=%d", total)
    return true
  end

  return false
end

function M.fail(state, i18n, tfn, reason)
  local total = tonumber(state.total) or 0
  -- warn, and with the reason: this is the path that puts "Loading failed" on the screen, and
  -- until now the reason went into a label and nowhere else -- so a page that failed to load
  -- left the same record as one that never tried.
  logf("warn", "load FAILED after %d/%d step(s) reason=%s",
    tonumber(state.done) or 0, total, tostring(reason))
  state.done = total
  state.progress = 1
  state.loading = false
  state.showLoadingOverlay = false

  local prefix = tfn(i18n, "loading_failed", "Loading failed")
  if reason and reason ~= "" then
    state.errorMessage = prefix .. ": " .. tostring(reason)
  else
    state.errorMessage = prefix
  end

  state.errorDialogShown = nil
end

function M.isTimedOut(state, nowSec)
  if state.loading ~= true then return false end
  local started = tonumber(state.loadingStartedAt) or 0
  local timeoutSec = tonumber(state.loadingTimeoutSec) or 12
  return (tonumber(nowSec) or 0) - started >= timeoutSec
end

-- The load failed and the pilot has to be told. This used to be a native lvgl.message,
-- which is a modal outside the tool's own run loop: while one stands, run() is not
-- reached, and whether a hardware key closes it depends on whether anything focusable was
-- created after it in the same build -- so a dialog raised mid-build can only be closed by
-- touch. It is now the tool's own notice box with one acknowledging button, which is drawn
-- into the page's own child list and needs no special case anywhere.
--
-- The caller supplies the geometry it is drawing into, because only the caller knows it.
function M.appendErrorNotice(children, opts, state, i18n, tfn)
  if type(children) ~= "table" or type(opts) ~= "table" or type(state) ~= "table" then
    return false
  end

  local message = state.errorMessage
  if type(message) ~= "string" or message == "" then
    return false
  end

  local overlay = opts.overlay
  if type(overlay) ~= "table" or type(overlay.appendNotice) ~= "function" then
    return false
  end

  overlay.appendNotice(children, {
    x = opts.x,
    y = opts.y,
    w = opts.w,
    h = opts.h,
    title = tfn(i18n, "loading_failed", "Loading failed"),
    message = message,
    -- "OK" rather than a lookup: no page bundle in the tree carries a key for it, so a
    -- lookup here would only be a lookup that fails.
    buttonText = "OK",
    press = function()
      state.errorMessage = nil
      state.errorDialogShown = nil
      if type(opts.requestRebuild) == "function" then
        opts.requestRebuild()
      end
    end
  })

  return true
end

function M.reset(state)
  state.loading = false
  state.showLoadingOverlay = false
  state.loadingStartedAt = 0
  state.progress = 0
  state.done = 0
  state.total = 0
  state.errorMessage = nil
  state.errorDialogShown = nil
end

return M
