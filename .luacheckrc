std = "lua54"

-- EdgeTX/OpenTX Ethos Environment Globals
globals = {
  -- Scripting Engine
  "loadScript",
  "loadModuleChunk",
  "registerTelemetry",
  "registerForm",
  "registerGadget",
  
  -- System/Time/Model
  "getTime",
  "getUsage",
  "system",
  "model",
  "getVersion",
  "getField",
  "setField",
  "getFieldInfo",
  "getSwitchIndex",
  "getGeneralSettings",
  "FUNC_PLAY_SCRIPT",

  -- Filesystem. These are bare globals of the firmware's filesystem library, not members of an
  -- os table -- this Lua has none -- so a guard written as os.remove can never pass and the
  -- name has to be spelled the way the radio publishes it.
  "fstat",
  "del",
  "rename",
  "mkdir",

  -- Shared memory between Lua states
  "setShmVar",
  "getShmVar",

  -- Telemetry/Sensors
  "getValue",
  "getSensor",
  "setTelemetryValue",
  
  -- Display/LCD
  "lcd",
  "lvgl",
  "LCD_W",
  "LCD_H",
  
  -- Colors
  "WHITE",
  "BLACK",
  "RED",
  "GREEN",
  "YELLOW",
  "BLUE",
  "MAGENTA",
  "CYAN",
  "COLOR_THEME_PRIMARY1",
  "COLOR_THEME_PRIMARY2",
  "COLOR_THEME_PRIMARY3",
  "COLOR_THEME_SECONDARY1",
  "COLOR_THEME_SECONDARY2",
  "COLOR_THEME_SECONDARY3",
  "COLOR_THEME_WARNING",
  "COLOR_THEME_DISABLED",
  "COLOR_THEME_FOCUS",
  "COLOR_THEME_ACTIVE",
  "COLOR_THEME_EDIT",
  
  -- Font sizes
  "DBLSIZE",
  "MIDSIZE",
  "SMLSIZE",
  "XXLSIZE",
  
  -- Alignment
  "CENTER",
  "LEFT",
  "RIGHT",
  "TOP",
  "BOTTOM",
  
  -- Bit operations
  "bit32",
  
  -- Global state (RF2/Ethos)
  "rfsuite",
  "Rf2Runtime",
  "_G",
}

-- Dashboard objects hand their value closures to lvgl.build, and the firmware's reactive
-- sweep then runs them per frame on the refresh's leftover budget, outside any pcall -- so
-- they read the precomputed `state.derived` snapshot and never probe. A probe re-introduced
-- into an object fails here instead of waiting for a reviewer's eye. `common.lua` is
-- exempt: it defines mapTelemetrySource, which widgets/dashboard/derived.lua calls from
-- the widget pass, where probing is legal.
local probe_globals = {
  ["model"] = true, ["getValue"] = true, ["getSensor"] = true, ["getFieldInfo"] = true,
  -- Reading the card is a probe like any other: derived.lua stats /IMAGES/ for the model
  -- picture, and an object doing the same would do it once per frame.
  ["fstat"] = true,
  -- And writing to it is worse than reading it, so the three that do are subtracted here too.
  -- Without this, naming them above would have quietly widened what an object may do.
  ["del"] = true, ["rename"] = true, ["mkdir"] = true,
}
local object_globals = {}
for _, g in ipairs(globals) do
  if not probe_globals[g] then
    object_globals[#object_globals + 1] = g
  end
end
-- `new_globals` rather than `globals`: a per-path `globals` is MERGED with the one above it,
-- so a shortened list handed to a path adds nothing and takes nothing away. `new_globals`
-- replaces, which is what a restriction has to do.
files["src/rfsuite/widgets/dashboard/objects"] = { new_globals = object_globals }
files["src/rfsuite/widgets/dashboard/objects/common.lua"] = { new_globals = globals }
-- The in-flight tuning surface hands lvgl.build the same kind of value closures and is under the
-- same rule for the same reason: they run per frame in the reactive sweep, on the leftover budget,
-- outside the pcall. It reads the snapshot its own drive publishes and probes nothing.
--
-- The same set of names as the objects rule above, and it names them directly because there is
-- one file rather than a directory: `not_globals` subtracts from the inherited list, which is
-- what a single-file restriction needs, and `new_globals` would have to repeat the whole list
-- to take four names out of it. Verified in both directions -- a planted `model` read in this
-- file reports "accessing undefined variable 'model'", and removing the entry silences it.
files["src/rfsuite/widgets/dashboard/inflight/screen.lua"] = {
  not_globals = { "model", "getValue", "getSensor", "getFieldInfo", "fstat",
                  "del", "rename", "mkdir" }
}

-- Code style rules
max_line_length = 140
max_code_line_length = 140

-- Allow unused arguments in functions (common in callbacks)
unused_args = false
unused_secondaries = false