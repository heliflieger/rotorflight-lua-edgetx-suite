local I18n = {}

local BASE_PATH = "/SCRIPTS/TOOLS/rfsuite-core/i18n/"
local bundleCache = {}
local strLower = string.lower
local strGsub = string.gsub
local strFind = string.find
local strSub = string.sub
local strUpper = string.upper

local function normalizeLocale(locale)
  if type(locale) ~= "string" or locale == "" then return "en" end
  local lower = strLower(locale)
  if strFind(lower, "_", 1, true) then
    lower = strGsub(lower, "_", "-")
  end
  return lower
end

local function tryLoad(locale)
  if type(locale) ~= "string" or locale == "" then return nil end

  local cached = bundleCache[locale]
  if cached ~= nil then
    if cached == false then return nil end
    return cached
  end

  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(BASE_PATH .. locale .. ".lua", mode)
  if not chunk then
    bundleCache[locale] = false
    return nil
  end

  local ok, bundle = pcall(chunk)
  if ok and type(bundle) == "table" then
    bundleCache[locale] = bundle
    return bundle
  end

  bundleCache[locale] = false
  return nil
end

local function selectBundle(locale)
  local normalized = normalizeLocale(locale)

  local bundle = tryLoad(normalized)
  if bundle then return bundle, normalized end

  local dash = strFind(normalized, "-", 1, true)
  if dash and dash > 1 then
    local base = strSub(normalized, 1, dash - 1)
    bundle = tryLoad(base)
    if bundle then return bundle, base end
  end

  local fallback = tryLoad("en") or {}
  return fallback, "en"
end

local function getPathValue(root, key)
  if type(root) ~= "table" or type(key) ~= "string" then
    return nil
  end

  local node = root
  local startPos = 1
  while true do
    if type(node) ~= "table" then
      return nil
    end

    local dotPos = strFind(key, ".", startPos, true)
    local part
    if dotPos then
      part = strSub(key, startPos, dotPos - 1)
      startPos = dotPos + 1
    else
      part = strSub(key, startPos)
    end

    node = node[part]
    if not dotPos then break end
  end

  return node
end

function I18n.new(locale)
  local active, activeLang = selectBundle(locale)
  local english = nil

  local function getEnglish()
    if english == nil then
      english = tryLoad("en") or {}
    end
    return english
  end

  local ctx = {}

  function ctx.t(key, fallback)
    local val = getPathValue(active, key)
    if val ~= nil then
      return val
    end

    if activeLang ~= "en" then
      local engVal = getPathValue(getEnglish(), key)
      if engVal ~= nil then return engVal end
    end

    return fallback or key
  end

  function ctx.setLocale(nextLocale)
    local nextBundle, lang = selectBundle(nextLocale)
    if type(nextBundle) == "table" then
      active = nextBundle
      activeLang = lang
      return true
    end
    return false
  end

  function ctx.getLocale()
    return activeLang
  end

  function ctx.resolve(value)
    if type(value) ~= "string" then
      return value
    end
    if not strFind(value, "@i18n(", 1, true) then
      return value
    end

    local text = value
    text = strGsub(text, "@i18n%(([^)]+)%)%:upper%(%)%@", function(k)
      return strUpper(ctx.t(k))
    end)
    text = strGsub(text, "@i18n%(([^)]+)%)%@", function(k)
      return ctx.t(k)
    end)

    return text
  end

  return ctx
end

return I18n
