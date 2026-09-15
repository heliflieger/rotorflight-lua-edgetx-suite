local DisplayProfile = {}

local function shallowCopy(src)
  local out = {}
  for k, v in pairs(src) do
    out[k] = v
  end
  return out
end

local BASE = {
  key = "tx16s",
  contentPad = 6,
  labelIndent = 6,
  tileGap = 10,
  groupTitleH = 22,
  groupDivH = 3,
  groupGapAfter = 8,
  rootMinCardWidth = 104,
  rootMaxColumns = 4,
  menuMinCardWidth = 104,
  menuMaxColumns = 4,
  wrapTiles = true,
  rootRowHeight = 112,
  tileMin = 70,
  tileMax = 104,
  groupGapBottom = 12,
  -- One SMLSIZE line plus padding: the strip ui/home.lua puts above the content while the
  -- craft is armed. About 0.6 of the header button height, and never below 24 px, which is
  -- what a touch target needs. Per resolution and read off each one -- the header row does
  -- not scale between them either.
  armedBannerH = 24,
  rowH = 40,
  horizontalRowH = 56,
  sectionH = 38,
  staticSectionH = 38,
  header = {
    rightPad = 12,
    memW = 110,
    topButtonWSmall = 36,
    topButtonWAction = 40,
    topButtonH = 34,
    topButtonGap = 3,
    topButtonY = 6,
    topButtonBorder = 2,
    memYOffset = 10
  }
}

local PRESETS = {
  tx16s = {},
  small = {
    key = "small",
    rowH = 34,
    horizontalRowH = 48,
    sectionH = 32,
    staticSectionH = 32
  },
  tx15 = {
    key = "tx15",
    rootMinCardWidth = 96,
    rootMaxColumns = 4,
    menuMinCardWidth = 96,
    menuMaxColumns = 4,
    wrapTiles = true,
    tileMin = 66,
    tileMax = 100,
    groupGapBottom = 10,
    armedBannerH = 24,
    rowH = 40,
    horizontalRowH = 56,
    sectionH = 38,
    staticSectionH = 38,
    header = {
      memW = 110,
      topButtonH = 34,
      topButtonY = 6
    }
  },
  tx16s_mk3 = {
    key = "tx16s_mk3",
    contentPad = 6,
    labelIndent = 6,
    tileGap = 12,
    groupTitleH = 24,
    groupDivH = 3,
    groupGapAfter = 10,
    rootMinCardWidth = 72,
    rootMaxColumns = 6,
    menuMinCardWidth = 72,
    menuMaxColumns = 6,
    wrapTiles = false,
    rootRowHeight = 120,
    tileMin = 80,
    tileMax = 112,
    groupGapBottom = 16,
    armedBannerH = 27,
    rowH = 50,
    horizontalRowH = 68,
    sectionH = 46,
    staticSectionH = 46,
    header = {
      rightPad = 20,
      memW = 126,
      topButtonWSmall = 45,
      topButtonWAction = 45,
      topButtonH = 45,
      topButtonGap = 4,
      topButtonY = 8,
      topButtonBorder = 2,
      memYOffset = 13
    }
  }
}

local function merge(base, override)
  local out = shallowCopy(base)
  for k, v in pairs(override) do
    if k == "header" and type(v) == "table" then
      out.header = shallowCopy(base.header)
      for hk, hv in pairs(v) do out.header[hk] = hv end
    else
      out[k] = v
    end
  end
  return out
end

function DisplayProfile.current()
  local w = _G.LCD_W or 480
  local h = _G.LCD_H or 272

  if w >= 760 then
    return merge(BASE, PRESETS.tx16s_mk3)
  end

  if w <= 320 then
    return merge(BASE, PRESETS.small)
  end

  if w == 480 and h >= 300 then
    return merge(BASE, PRESETS.tx15)
  end

  return merge(BASE, PRESETS.tx16s)
end

return DisplayProfile
