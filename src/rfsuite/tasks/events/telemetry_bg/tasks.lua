local M = {}

local Drain = nil
local Smart = nil
local Adjustments = nil

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local function nowSeconds()
    if type(getTime) == "function" then
        local ok, v = pcall(getTime)
        if ok and type(v) == "number" then return v / 100 end
    end
    if type(os) == "table" and type(os.clock) == "function" then return os.clock() end
    return 0
end

function M.wakeup()
    -- One module per wakeup: each of these pulls in a subtree of its own -- smart.lua alone
    -- reaches the sensor library, the reserve helper and the logger, and drain.lua reaches
    -- the decoder table and the CRSF multiplexer -- and loading them together puts every one
    -- of those top-level chunks into a single widget pass, which is the pass class that runs
    -- closest to the firmware's per-call instruction limit.
    --
    -- `false` rather than a retry: with `not Smart` as the test a module that cannot be
    -- loaded is asked for again on every wakeup, which is a failing card read ten times a
    -- second for as long as the radio is on. Every use below is already guarded, so a
    -- module that is genuinely absent stays absent cheaply.
    if Drain == nil then
        Drain = loadModule("tasks/events/telemetry_bg/drain.lua") or false
        return
    end
    if Smart == nil then
        Smart = loadModule("tasks/events/telemetry_bg/smart.lua") or false
        return
    end
    if Adjustments == nil then
        Adjustments = loadModule("tasks/events/telemetry_bg/adjustments.lua") or false
        return
    end

    local now = nowSeconds()

    -- The background function script drains and tells for the whole radio while it is running,
    -- so this pass does neither: the sensors it would publish are already on the radio, and the
    -- teller would announce the same adjustment a second time. Both are dropped together, never
    -- one without the other.
    --
    -- Smart is NOT part of the handover. Its inputs are MSP-derived and its state is per Lua
    -- state, so the script has no way to compute it for this one.
    local remote = Drain and Drain.remoteAlive(now)

    if Drain and not remote then
        Drain.wakeup(now)
    end

    if Smart and type(Smart.wakeup) == "function" then
        Smart.wakeup()
    end

    -- After the decode, never before it: what the teller reads is what the drain has just
    -- published, so the other order would announce one pass behind.
    if not remote and Adjustments and type(Adjustments.wakeup) == "function" then
        Adjustments.wakeup()
    end
end

function M.reset()
    if Drain and type(Drain.reset) == "function" then
        Drain.reset()
    end
    if Smart and type(Smart.reset) == "function" then
        Smart.reset()
    end
    if Adjustments and type(Adjustments.reset) == "function" then
        Adjustments.reset()
    end
end

return M
