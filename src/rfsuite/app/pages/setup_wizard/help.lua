local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

-- Help is per PROCEDURE rather than per page. The screens carry controls and the sentences live
-- here, which is what keeps a screen inside its own height: every explanatory line removed from
-- the body is a control row gained.
--
-- Their help registry is keyed by menu id and a procedure is not a manifest entry, so the route
-- from a procedure to its text does not exist in the tree -- this is that route, kept small.
return function(ctx, proc)
  local Common = loadModule("app/pages/settings/common.lua")
  local t = Common and Common.pageT("setup_wizard") or function(_, _, fb) return fb end
  local i18n = ctx and ctx.i18n

  -- Written out per procedure, and the repetition is not clumsiness.
  --
  -- This used to build the key -- `"help_" .. proc.id` -- and hand it to the translator. Their
  -- packager rewrites a translated call only where the KEY and the FALLBACK are both literal at
  -- the call site, and it drops the locale tables from the card, so a key assembled at runtime
  -- can never resolve to anything: every one of these was the English fallback in the German
  -- build, and nothing anywhere went red. Found when the same mistake was made a second time on
  -- the closing screen and shipped.
  -- Each call carries a literal key AND a literal fallback, and the fallback is ONE string.
  --
  -- Their pattern is `t(i18n, "key", "fallback")` with both quoted and the bracket straight after.
  -- A third argument of `nil` fails it, and so does a fallback assembled with `..` -- the pattern
  -- matches the first quoted run and then wants the closing bracket, which a concatenation does
  -- not give it. Both mistakes were made here in one afternoon and both shipped English into the
  -- German build. So these fallbacks are short: they are only ever seen in a locale that has no
  -- entry for the key, and the locale that matters has one.
  local id = proc and tostring(proc.id) or nil
  local body = nil
  if id == "link" then
    body = t(i18n, "help_link", "The board does not measure the link. It is told how the link runs and paces its telemetry from that.")
  elseif id == nil then
    body = t(i18n, "help_opening", "This assistant walks the first setup of a bare flight controller. Each procedure can also be run alone.")
  end
  if body == nil or body == "" then
    body = t(i18n, "help_general", "This assistant walks the first setup of a bare flight controller. It proposes, shows what it will do, and writes only after a press.")
  end

  return {
    title = t(i18n, "help_title", "Setup Assistant"),
    message = body
  }
end
