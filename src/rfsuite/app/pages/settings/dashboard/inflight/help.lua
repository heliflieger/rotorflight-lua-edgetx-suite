-- The translator reaches this sheet through the house form: a `pageT` call the i18n precompiler
-- can derive a prefix from, and a wrapper named `t`, which is one of the two call names the
-- precompiler's pattern knows. A hand-rolled wrapper spelled anything else is a runtime lookup
-- only, and a packaged card carries no locale bundle, so the sheet would ship its English
-- fallbacks into a German install (#284).
local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

-- The blank line between two paragraphs of the help sheet.
local NL = "\n\n"

return function(ctx)
  local Common = loadModule("app/pages/settings/common.lua")
  local t = Common and Common.pageT("settings_dashboard_inflight") or function(_, _, fb) return fb end
  local i18n = ctx and ctx.i18n or nil

  local intro = t(i18n, "help_message",
    "Choose the interlock switch and the channels, variables and trims the overlay uses on this radio.")

  -- Whose settings these are, which is the first thing a pilot with two models needs to know and
  -- the reason nothing on this page asks for a flight controller.
  local owner = t(i18n, "help_owner",
    "They belong to the radio and apply to every model on it. No flight controller is needed to change them.")

  -- The one button on this page that changes anything but the settings, so the help says what it
  -- writes and that it asks first. Its counterpart -- the one that writes the flight controller's
  -- own adjustment slots -- went to the page that owns the flight controller's half.
  local setup = t(i18n, "help_setup",
    "Set up the model writes only what differs from the model, after showing it, and says so when nothing does.")

  -- The trim layout is the one setting a pilot meets with his thumbs rather than his eyes, so
  -- the help says what each of the three trims does rather than leaving the field labels to
  -- carry it on their own.
  local trims = t(i18n, "help_trims",
    "Walk and adjust: the bank trim steps the bank, the walk trim the row in it, the adjust trim the value.")

  -- The link carries these two channels, and an ExpressLRS switch mode quantises both of them to a
  -- fixed number of positions. The windows the flight controller decodes are 50 microseconds wide,
  -- so a quantised code can land in the gap beside its own window or inside the neighbouring row's.
  local link = t(i18n, "help_link", "On an ExpressLRS link use the Wide switch mode or a full-resolution packet rate: in Hybrid mode the value and bank channels carry 16 and 6 positions, so several rows and two banks miss their windows and one row moves its neighbour's parameter.")

  -- Where the other half is. The split is the pilot's after the third radio round and the one
  -- thing it costs him is knowing which page a setting is on, so both pages say.
  local flow = t(i18n, "help_flow", "The flight controller's own half, and the switch belonging to each model, are in Setup > Controls > In-Flight Tuning.")

  -- The switch that shows the feature at all is not on this page, and the widget adopts a
  -- change to it on its own clock: the preferences reload it depends on is held back while
  -- the craft is armed, so a switch thrown in the air is taken up on the ground.
  local preview = t(i18n, "help_preview",
    "Settings > General > Preview is what shows this feature. The widget takes a change to it after landing.")

  return {
    message = intro .. NL .. owner .. NL .. trims .. NL .. link .. NL .. setup .. NL .. flow .. NL .. preview
  }
end
