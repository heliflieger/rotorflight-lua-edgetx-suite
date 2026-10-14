local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

-- Key and fallback are both written out as literals in every call below. Their precompiler
-- rewrites a translated call only in that shape, and a fallback handed in through a variable
-- would stay English in every language with nothing anywhere reporting it.
return function(ctx)
  local Common = loadModule("app/pages/settings/common.lua")
  local t = Common and Common.pageT("tools_flight_log") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1", "A line per flight is written to the card once the log is switched on under Settings.")
  local help_p2 = t(i18n, "help_p2", "A flight is the time between arming and disarming. An arm shorter than the minimum is not one.")
  local help_p3 = t(i18n, "help_p3", "A pack picked under Batteries goes into the flight's line and its first flight counts one cycle.")
  local help_p4 = t(i18n, "help_p4", "A pack with no model list is offered for every craft, otherwise only for the names listed.")
  local help_p5 = t(i18n, "help_p5", "Both files are plain text. An edit rewrites one line and leaves the rest of the file alone.")
  local help_p6 = t(i18n, "help_p6", "The tab you are on is marked. Editing a pack takes the whole screen until Save or Cancel.")
  local help_p7 = t(i18n, "help_p7", "With the prompt on, the dashboard offers this model's packs in fullscreen once after connecting.")
  local help_p8 = t(i18n, "help_p8", "A pick in the prompt can also set the flight controller's battery profile, never while armed.")
  local help_p9 = t(i18n, "help_p9",
    "Cells: where the flight controller keeps a cell count per profile, it has to match it too; 0 leaves it out. A tie sets no profile.")

  local parts = { help_p1, help_p2, help_p3, help_p4, help_p5, help_p6, help_p7, help_p8, help_p9 }

  return {
    title = t(i18n, "help_title", "Flight Log Help"),
    message = table.concat(parts, "\n\n")
  }
end
