-- Flight Log.
--
-- Reads the two files lib/flight_log.lua writes: the flight list, per-model totals, the battery
-- registry with its editor, and the settings that decide whether anything is written at all.
--
-- The log is walked in bounded steps from `wakeup`, never from `build`. A build cannot be
-- interrupted, so reading a season's worth of flights in one would stand the tool still with
-- nothing on the screen; the build draws the notice and the walk happens behind it.
--
-- Only the newest few hundred flights are kept as rows -- that is what the list can show -- but
-- the totals count every line the file holds.

local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Common = nil
local Controls = nil
local FlightLog = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local t = nil

-- The rows kept for display. Everything past this still counts towards the totals.
local MAX_ROWS = 300
-- Lines parsed per wakeup. The line count is the binding cap rather than a byte budget, so a
-- file of wide rows takes the same number of passes as one of narrow rows.
local LINES_PER_WAKEUP = 90

local ROW_H = 34
local PROFILE_MAX = 6
-- The Battery page's own bound for a profile's cell count.
local CELLS_MAX = 24

local ui = {
  view = "flights",
  loaded = false,
  loading = false,
  loadPending = false,
  reader = nil,
  rows = {},
  rowCount = 0,
  totalSeconds = 0,
  models = {},
  modelOrder = {},
  flightsByBattery = {},
  registry = {},
  ordered = nil,
  page = 0,
  filterModel = nil,
  flight = nil,
  batteryId = nil,
  edit = nil,
  editMode = nil,
  editError = nil,
  config = { enabled = false, min_seconds = 30, ask_on_connect = false, set_fc_profile = false },
  requestRebuild = nil
}

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not FlightLog then FlightLog = loadModule("lib/flight_log.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not t then t = Common and Common.pageT("tools_flight_log") or nil end
end

-- Every key below is written out in full. The packager resolves a translation whose key is a
-- literal and leaves a computed one to reach the radio as a raw marker.
local function pageText(i18n, key, fallback)
  if t then
    local translated = t(i18n, key, fallback)
    if translated ~= nil and translated ~= "" and translated ~= key then
      return translated
    end
  end
  return fallback
end

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function requestRebuild()
  if type(ui.requestRebuild) == "function" then ui.requestRebuild() end
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

local function formatDuration(seconds)
  local s = math.floor(tonumber(seconds) or 0)
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- Below an hour a "h:mm" total reads "0:00" for a whole season of short flights.
local function formatTotal(seconds)
  local s = math.floor(tonumber(seconds) or 0)
  if s < 3600 then return formatDuration(s) end
  return string.format("%d:%02d h", math.floor(s / 3600), math.floor(s / 60) % 60)
end

local function batteryLabel(id)
  if type(id) ~= "string" or id == "" then return "-" end
  local entry = FlightLog and FlightLog.findById(ui.registry, id) or nil
  if entry and type(entry.name) == "string" and entry.name ~= "" then return entry.name end
  return id
end

-- ---------------------------------------------------------------------------
-- Loading
-- ---------------------------------------------------------------------------

local function resetAggregates()
  ui.rows = {}
  ui.rowCount = 0
  ui.totalSeconds = 0
  ui.models = {}
  ui.modelOrder = {}
  ui.flightsByBattery = {}
  ui.ordered = nil
end

local function addRow(row)
  ui.rowCount = ui.rowCount + 1
  ui.rows[((ui.rowCount - 1) % MAX_ROWS) + 1] = row
  ui.totalSeconds = ui.totalSeconds + row.seconds

  if row.model ~= "" then
    local entry = ui.models[row.model]
    if entry == nil then
      entry = { count = 0, seconds = 0 }
      ui.models[row.model] = entry
      ui.modelOrder[#ui.modelOrder + 1] = row.model
    end
    entry.count = entry.count + 1
    entry.seconds = entry.seconds + row.seconds
  end

  if row.battery ~= "" then
    ui.flightsByBattery[row.battery] = (ui.flightsByBattery[row.battery] or 0) + 1
  end
end

-- The ring in reading order, newest first. Built once when the walk is over rather than on
-- every build.
local function orderedRows()
  if ui.ordered ~= nil then return ui.ordered end
  local out = {}
  local first = math.max(1, ui.rowCount - MAX_ROWS + 1)
  for i = ui.rowCount, first, -1 do
    out[#out + 1] = ui.rows[((i - 1) % MAX_ROWS) + 1]
  end
  ui.ordered = out
  return out
end

local function visibleRows()
  local all = orderedRows()
  if ui.filterModel == nil then return all end
  local out = {}
  for i = 1, #all do
    if all[i].model == ui.filterModel then out[#out + 1] = all[i] end
  end
  return out
end

local function loadRegistry()
  if not FlightLog then return end
  local ok, registry = pcall(FlightLog.loadRegistry)
  ui.registry = (ok and type(registry) == "table") and registry or {}
end

local function startLoad()
  if not FlightLog then return end
  resetAggregates()
  loadRegistry()
  ui.reader = FlightLog.newReader(FlightLog.csvPath())
  ui.loading = ui.reader ~= nil
  ui.loadPending = false
  if ui.reader == nil then
    -- No file yet is the normal state of a radio that has never flown with the log on. There
    -- is nothing to read and nothing to say about it beyond the empty list.
    ui.ordered = nil
  end
end

local function loadConfig(preferences)
  local section = type(preferences) == "table" and preferences.flightlog or nil
  if type(section) == "table" then
    ui.config.enabled = section.enabled == true
    ui.config.min_seconds = tonumber(section.min_seconds) or 30
    ui.config.ask_on_connect = section.ask_on_connect == true
    ui.config.set_fc_profile = section.set_fc_profile == true
  else
    ui.config.enabled = false
    ui.config.min_seconds = 30
    ui.config.ask_on_connect = false
    ui.config.set_fc_profile = false
  end
end

local function ensureLoaded(preferences)
  if ui.loaded then return end
  ui.loaded = true
  loadConfig(preferences)
  ui.loadPending = true
  ui.loading = true
end

-- ---------------------------------------------------------------------------
-- The battery for the next flight
-- ---------------------------------------------------------------------------

local function selectedBatteryId()
  local session = getSession()
  local record = session and session.flightlog or nil
  if type(record) == "table" and type(record.batteryId) == "string" and record.batteryId ~= "" then
    return record.batteryId
  end
  return FlightLog.storedBatteryId(session and session.modelPreferences)
end

-- The choice is kept twice on purpose: in the session, where the arm edge reads it, and in the
-- model's own store, so that the same pack is offered again next time this craft is connected.
--
-- The recording itself is lib/battery_pick.lua's, and there is one implementation of it: the
-- dashboard's picker writes the same two places from the same code, so a pack picked here and a
-- pack picked there cannot end up recorded differently.
local function selectBattery(id)
  local session = getSession()
  if type(session) ~= "table" then return end
  local BatteryPick = loadModule("lib/battery_pick.lua")
  if type(BatteryPick) ~= "table" or type(BatteryPick.select) ~= "function" then return end
  BatteryPick.select(session, id)
end

-- ---------------------------------------------------------------------------
-- Page hooks
-- ---------------------------------------------------------------------------

function M.getHeaderActions()
  return {
    save = ui.view == "settings",
    reload = true,
    help = true,
    menu = true
  }
end

function M.wakeup(ctx)
  ensureDeps()
  if type(ctx) == "table" then
    if type(ctx.requestRebuild) == "function" then ui.requestRebuild = ctx.requestRebuild end
    ensureLoaded(ctx.preferences)
  end

  if ui.loadPending then
    startLoad()
    if not ui.loading then requestRebuild() end
    return
  end

  if ui.loading and ui.reader ~= nil then
    local ok, finished = pcall(FlightLog.readerStep, ui.reader, LINES_PER_WAKEUP, addRow)
    if not ok or finished then
      pcall(FlightLog.readerClose, ui.reader)
      ui.reader = nil
      ui.loading = false
      ui.ordered = nil
      if type(collectgarbage) == "function" then collectgarbage("collect") end
      requestRebuild()
    end
  end
end

function M.onReload(ctx)
  ensureDeps()
  if ui.reader ~= nil then
    pcall(FlightLog.readerClose, ui.reader)
    ui.reader = nil
  end
  if type(ctx) == "table" then loadConfig(ctx.preferences) end
  ui.page = 0
  ui.flight = nil
  ui.edit = nil
  ui.editMode = nil
  ui.editError = nil
  -- A view that shows a record which has just been cleared has to go back to its list. The pack
  -- detail re-resolves its id against the reloaded registry and says so when the pack is really
  -- gone; a flight detail has no id to re-resolve, so it would draw the empty-log notice on a
  -- radio whose log is full.
  if ui.view == "flight" then ui.view = "flights" end
  ui.loadPending = true
  ui.loading = true
  requestRebuild()
  return true
end

-- Back walks the views it came through before it leaves the page.
function M.onBack()
  if ui.edit ~= nil then
    ui.edit = nil
    ui.editMode = nil
    ui.editError = nil
    requestRebuild()
    return true
  end
  if ui.view == "battery" then
    ui.view = "batteries"
    ui.batteryId = nil
    requestRebuild()
    return true
  end
  if ui.view == "flight" then
    ui.view = "flights"
    ui.flight = nil
    requestRebuild()
    return true
  end
  if ui.filterModel ~= nil then
    ui.filterModel = nil
    ui.page = 0
    ui.view = "models"
    requestRebuild()
    return true
  end
  if ui.view ~= "flights" then
    ui.view = "flights"
    ui.page = 0
    requestRebuild()
    return true
  end
  return false
end

function M.onSave(ctx)
  ensureDeps()
  if type(ctx) ~= "table" or type(ctx.preferences) ~= "table" then return false end
  if type(ctx.preferences.flightlog) ~= "table" then ctx.preferences.flightlog = {} end
  ctx.preferences.flightlog.enabled = ui.config.enabled == true
  ctx.preferences.flightlog.min_seconds = math.floor(tonumber(ui.config.min_seconds) or 30)
  ctx.preferences.flightlog.ask_on_connect = ui.config.ask_on_connect == true
  ctx.preferences.flightlog.set_fc_profile = ui.config.set_fc_profile == true

  if type(ctx.savePreferences) ~= "function" then return false end
  local ok, err = ctx.savePreferences()
  if ok then
    return true
  end
  if type(ctx.reportSave) == "function" then
    ctx.reportSave({
      title = pageText(ctx.i18n, "error_title", "Error"),
      message = pageText(ctx.i18n, "error_io", "The card did not take the write") .. ": " .. tostring(err or "io")
    })
  end
  return false
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/tools/flight_log/help.lua")
  if type(help) == "function" then return help(ctx) end
  return { title = "Help", message = "No help available" }
end

function M.onClose()
  if FlightLog and ui.reader ~= nil then
    pcall(FlightLog.readerClose, ui.reader)
  end
  ui.reader = nil
  ui.loaded = false
  ui.loading = false
  ui.loadPending = false
  ui.view = "flights"
  ui.page = 0
  ui.filterModel = nil
  ui.flight = nil
  ui.batteryId = nil
  ui.edit = nil
  ui.editMode = nil
  ui.editError = nil
  ui.requestRebuild = nil
  resetAggregates()
  ui.registry = {}
  Common = nil
  Controls = nil
  FlightLog = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  t = nil
  if type(collectgarbage) == "function" then collectgarbage("collect") end
end

-- ---------------------------------------------------------------------------
-- Drawing helpers
-- ---------------------------------------------------------------------------

local function appendLabel(children, x, y, w, text, color, align)
  children[#children + 1] = {
    type = "label",
    x = x,
    y = y,
    w = w,
    text = text,
    color = color or COLOR_THEME_PRIMARY1,
    font = SMLSIZE,
    align = align
  }
end

local function appendDivider(children, x, y, w)
  children[#children + 1] = {
    type = "rectangle",
    x = x,
    y = y,
    w = w,
    h = 1,
    color = COLOR_THEME_SECONDARY2,
    filled = true
  }
end

-- `checked` is the firmware's own active state for a text button and may be left out; a button
-- that never passes it is drawn exactly as it was before.
local function appendButton(children, x, y, w, h, text, press, checked)
  children[#children + 1] = {
    type = "button",
    x = x,
    y = y,
    w = w,
    h = h,
    text = text,
    press = press,
    checked = checked
  }
end

local TABS = { "flights", "models", "batteries", "settings" }

-- The tab row's own height and the gap below it. Both are named because the body is laid out
-- before the row is appended -- see M.build.
local TAB_ROW_H = 30
local TAB_ROW_GAP = 8

local function tabLabel(i18n, view)
  if view == "flights" then return pageText(i18n, "tab_flights", "Flights") end
  if view == "models" then return pageText(i18n, "tab_models", "Models") end
  if view == "batteries" then return pageText(i18n, "tab_batteries", "Batteries") end
  return pageText(i18n, "tab_settings", "Settings")
end

-- Which tab a view belongs under. A single flight and a list filtered to one model are still the
-- flights tab, and a pack's own detail is still the batteries tab.
local function activeTab()
  if ui.view == "flight" then return "flights" end
  if ui.view == "battery" then return "batteries" end
  return ui.view
end

-- Whether a press on this tab would write the state the page is already in.
local function tabIsCurrent(view)
  return ui.view == view and ui.page == 0 and ui.edit == nil
    and ui.flight == nil and ui.batteryId == nil and ui.filterModel == nil
end

local function makeTabPress(view)
  return function()
    -- Nothing to do, so nothing is rebuilt. The firmware takes a press handler's return value as
    -- the button's new checked state (ButtonBase::onPress in gui/colorlcd/libui/button.cpp), so
    -- the answer has to be 1: returning nothing would clear the active mark and leave it cleared,
    -- because only a rebuild sets it again.
    if tabIsCurrent(view) then return 1 end
    ui.view = view
    ui.page = 0
    ui.flight = nil
    ui.batteryId = nil
    -- A tab leads to its own list. The model filter is part of what the flights tab is showing,
    -- so it goes the same way the page number and the open record do.
    ui.filterModel = nil
    ui.edit = nil
    ui.editMode = nil
    ui.editError = nil
    requestRebuild()
  end
end

local function appendTabs(children, x, y, w, i18n)
  local gap = 4
  local count = #TABS
  local btnW = math.floor((w - (count - 1) * gap) / count)
  local active = activeTab()
  for i = 1, count do
    local view = TABS[i]
    appendButton(children, x + (i - 1) * (btnW + gap), y, btnW, TAB_ROW_H,
      tabLabel(i18n, view), makeTabPress(view), view == active)
  end
end

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

local function buildFlights(children, x, y, w, h, i18n)
  local cursorY = y
  local rows = visibleRows()

  local heading
  if ui.filterModel ~= nil then
    -- The counts come from the aggregate rather than from the visible rows: the ring holds the
    -- newest few hundred flights, the totals hold every line the file has.
    local entry = ui.models[ui.filterModel]
    heading = string.format("%s  -  %d  -  %s", ui.filterModel, entry and entry.count or #rows,
      formatTotal(entry and entry.seconds or 0))
  else
    -- The label rather than a counted noun: "1 flights" is what a plural in a format string
    -- gets you, and every language this is translated into pluralises differently anyway.
    heading = string.format("%s: %d  -  %s", pageText(i18n, "tab_flights", "Flights"),
      ui.rowCount, formatTotal(ui.totalSeconds))
  end
  -- PRIMARY1 rather than PRIMARY2: the summary line sits on the page background rather than on a
  -- header, and PRIMARY2 is the colour the themes reserve for text that already has one behind it.
  appendLabel(children, x + 6, cursorY + 4, w - 12, heading, COLOR_THEME_PRIMARY1)
  cursorY = cursorY + 26
  appendDivider(children, x, cursorY, w)
  cursorY = cursorY + 4

  if #rows == 0 then
    appendLabel(children, x + 10, cursorY + 20, w - 20,
      pageText(i18n, "no_flights", "No flights recorded yet"), COLOR_THEME_DISABLED, CENTER)
    return
  end

  local pagerH = 36
  local available = h - (cursorY - y) - pagerH
  local perPage = math.max(1, math.floor(available / ROW_H))
  local pages = math.max(1, math.ceil(#rows / perPage))
  if ui.page >= pages then ui.page = pages - 1 end
  if ui.page < 0 then ui.page = 0 end

  local first = ui.page * perPage + 1
  local last = math.min(#rows, first + perPage - 1)

  local btnW = 34
  local btnX = x + w - btnW - 8
  local dateW = math.min(150, math.floor(w * 0.34))
  local durW = 60
  local modelX = x + dateW + 12
  local modelW = math.max(40, btnX - modelX - durW - 16)

  for i = first, last do
    local row = rows[i]
    appendLabel(children, x + 6, cursorY + 8, dateW,
      string.format("%s %s", row.date, string.sub(row.time, 1, 5)))
    appendLabel(children, modelX, cursorY + 8, modelW,
      string.format("%s  %s", row.model ~= "" and row.model or "-", batteryLabel(row.battery)),
      COLOR_THEME_DISABLED)
    appendLabel(children, btnX - durW - 8, cursorY + 8, durW, formatDuration(row.seconds),
      COLOR_THEME_PRIMARY1, RIGHT)
    appendButton(children, btnX, cursorY + 3, btnW, 28, ">", function()
      ui.flight = row
      ui.view = "flight"
      requestRebuild()
    end)
    appendDivider(children, x, cursorY + ROW_H - 1, w)
    cursorY = cursorY + ROW_H
  end

  if pages > 1 then
    local pagerY = cursorY + 4
    appendButton(children, x + 6, pagerY, 60, 28, pageText(i18n, "prev", "Prev"), function()
      if ui.page > 0 then
        ui.page = ui.page - 1
        requestRebuild()
      end
    end)
    appendLabel(children, x + 74, pagerY + 6, w - 150,
      string.format("%d / %d", ui.page + 1, pages), COLOR_THEME_DISABLED, CENTER)
    appendButton(children, x + w - 66, pagerY, 60, 28, pageText(i18n, "next", "Next"), function()
      if ui.page < pages - 1 then
        ui.page = ui.page + 1
        requestRebuild()
      end
    end)
  end
end

-- The statistics columns a line may carry. The disarm task fills them from the flight record
-- (tasks/events/ondisarm/tasks/flight_log.lua, flightStats), and a line from another writer may
-- carry any of them. Every key is spelled out because the packager resolves a literal key and
-- leaves a computed one to reach the radio as a raw marker.
local function statLabels(i18n)
  return {
    mah = pageText(i18n, "stat_mah", "Consumed"),
    vcel_min = pageText(i18n, "stat_vcel_min", "Cell voltage min"),
    vcel_max = pageText(i18n, "stat_vcel_max", "Cell voltage max"),
    hs1_min = pageText(i18n, "stat_hs1_min", "Headspeed 1 min"),
    hs1_max = pageText(i18n, "stat_hs1_max", "Headspeed 1 max"),
    hs2_min = pageText(i18n, "stat_hs2_min", "Headspeed 2 min"),
    hs2_max = pageText(i18n, "stat_hs2_max", "Headspeed 2 max"),
    hs3_min = pageText(i18n, "stat_hs3_min", "Headspeed 3 min"),
    hs3_max = pageText(i18n, "stat_hs3_max", "Headspeed 3 max"),
    curr_min = pageText(i18n, "stat_curr_min", "Current min"),
    curr_max = pageText(i18n, "stat_curr_max", "Current max"),
    tesc_min = pageText(i18n, "stat_tesc_min", "ESC temperature min"),
    tesc_max = pageText(i18n, "stat_tesc_max", "ESC temperature max"),
    vbec_min = pageText(i18n, "stat_vbec_min", "BEC voltage min"),
    vbec_max = pageText(i18n, "stat_vbec_max", "BEC voltage max"),
    sags = pageText(i18n, "stat_sags", "Voltage sags"),
    sag_min = pageText(i18n, "stat_sag_min", "Deepest sag")
  }
end

local function appendField(children, x, y, w, label, value)
  local labelW = math.max(90, math.min(190, math.floor(w * 0.40)))
  appendLabel(children, x + 6, y + 6, labelW, label)
  appendLabel(children, x + labelW + 12, y + 6, w - labelW - 20, value, COLOR_THEME_DISABLED)
  appendDivider(children, x, y + 28, w)
  return 29
end

local function buildFlight(children, x, y, w, h, i18n)
  local row = ui.flight
  local cursorY = y
  if row == nil then
    appendLabel(children, x + 10, cursorY + 20, w - 20,
      pageText(i18n, "no_flights", "No flights recorded yet"), COLOR_THEME_DISABLED, CENTER)
    return
  end

  -- A single flight is not one of the tabs, so nothing in the row above says which one is open:
  -- its heading has to. The date and the time are what identify it, and they are here rather than
  -- repeated as two rows of their own below.
  appendLabel(children, x + 6, cursorY, w - 12,
    string.format("%s %s", row.date, row.time), COLOR_THEME_PRIMARY1)
  cursorY = cursorY + 22

  cursorY = cursorY + appendField(children, x, cursorY, w, pageText(i18n, "field_model", "Model"),
    row.model ~= "" and row.model or "-")
  cursorY = cursorY + appendField(children, x, cursorY, w, pageText(i18n, "field_battery", "Battery"),
    batteryLabel(row.battery))
  cursorY = cursorY + appendField(children, x, cursorY, w, pageText(i18n, "field_duration", "Duration"),
    formatDuration(row.seconds))

  local stats = row.stats and FlightLog.parseStats(row.stats) or nil
  if stats == nil then
    appendLabel(children, x + 6, cursorY + 10, w - 12,
      pageText(i18n, "no_stats", "This flight was recorded without statistics."), COLOR_THEME_DISABLED)
    return
  end

  cursorY = cursorY + 6
  appendLabel(children, x + 6, cursorY, w - 12, pageText(i18n, "stats_title", "Statistics"), COLOR_THEME_PRIMARY1)
  cursorY = cursorY + 22
  local labels = statLabels(i18n)
  for i = 1, #FlightLog.STAT_KEYS do
    local key = FlightLog.STAT_KEYS[i]
    local value = stats[key]
    if value ~= nil then
      cursorY = cursorY + appendField(children, x, cursorY, w, labels[key] or key, tostring(value))
    end
  end
end

local function buildModels(children, x, y, w, h, i18n)
  local cursorY = y
  if #ui.modelOrder == 0 then
    appendLabel(children, x + 10, cursorY + 20, w - 20,
      pageText(i18n, "no_flights", "No flights recorded yet"), COLOR_THEME_DISABLED, CENTER)
    return
  end

  local btnW = 34
  local btnX = x + w - btnW - 8
  local countW = 70
  local timeW = 80

  for i = 1, #ui.modelOrder do
    local name = ui.modelOrder[i]
    local entry = ui.models[name]
    appendLabel(children, x + 6, cursorY + 8, btnX - timeW - countW - 24, name)
    appendLabel(children, btnX - timeW - countW - 12, cursorY + 8, countW, tostring(entry.count),
      COLOR_THEME_DISABLED, RIGHT)
    appendLabel(children, btnX - timeW - 8, cursorY + 8, timeW, formatTotal(entry.seconds),
      COLOR_THEME_DISABLED, RIGHT)
    appendButton(children, btnX, cursorY + 3, btnW, 28, ">", function()
      ui.filterModel = name
      ui.view = "flights"
      ui.page = 0
      requestRebuild()
    end)
    appendDivider(children, x, cursorY + ROW_H - 1, w)
    cursorY = cursorY + ROW_H
  end
end

local function batteryOptions(i18n)
  local session = getSession()
  local modelName = session and session.modelName or nil
  local list = FlightLog.forModel(ui.registry, modelName or "")
  local options = { { value = "", label = pageText(i18n, "battery_none", "None") } }
  for i = 1, #list do
    local entry = list[i]
    options[#options + 1] = {
      value = entry.id,
      label = (type(entry.name) == "string" and entry.name ~= "") and entry.name or entry.id
    }
  end
  return options
end

local function startEdit(entry)
  local models = ""
  if type(entry) == "table" and type(entry.models) == "table" then
    models = table.concat(entry.models, ",")
  end
  ui.edit = {
    originalId = entry and entry.id or nil,
    id = entry and entry.id or FlightLog.freeId(ui.registry),
    name = entry and entry.name or "",
    cap = tonumber(entry and entry.cap) or 0,
    cells = tonumber(entry and entry.cells) or 0,
    models = models,
    profile = tonumber(entry and entry.profile) or 0,
    cycles = tonumber(entry and entry.cycles) or 0
  }
  ui.editMode = entry and "edit" or "create"
  ui.editError = nil
end

local function errorText(i18n, result)
  if result == "collision" then
    return pageText(i18n, "error_collision", "That id already belongs to another pack")
  end
  if result == "toobig" then
    return pageText(i18n, "error_toobig", "The registry is too large to be rewritten safely")
  end
  if result == "notfound" then
    return pageText(i18n, "error_notfound", "That pack is no longer in the file")
  end
  return pageText(i18n, "error_io", "The card did not take the write")
end

local function saveEdit(i18n)
  local edit = ui.edit
  if type(edit) ~= "table" then return end

  local id = FlightLog.sanitizeId(edit.id)
  if id == "" then
    ui.editError = pageText(i18n, "error_id_required", "A pack needs an id")
    requestRebuild()
    return
  end

  local models = edit.models
  if FlightLog.trim(models) == "" then models = false end

  local result
  if ui.editMode == "create" then
    result = FlightLog.createBattery({
      id = id,
      name = FlightLog.sanitizeName(edit.name),
      cap = tonumber(edit.cap) or 0,
      cells = tonumber(edit.cells) or 0,
      models = models,
      profile = tonumber(edit.profile) or 0,
      cycles = tonumber(edit.cycles) or 0
    })
  else
    result = FlightLog.updateBattery(edit.originalId, {
      id = id,
      name = FlightLog.sanitizeName(edit.name),
      cap = (tonumber(edit.cap) or 0) > 0 and math.floor(edit.cap) or false,
      cells = (tonumber(edit.cells) or 0) >= 1 and math.floor(edit.cells) or false,
      models = models,
      profile = (tonumber(edit.profile) or 0) >= 1 and math.floor(edit.profile) or false,
      cycles = math.floor(tonumber(edit.cycles) or 0)
    })
  end

  if result ~= true then
    ui.editError = errorText(i18n, result)
    requestRebuild()
    return
  end

  loadRegistry()

  -- The pack for the next flight is remembered by id, so a rename has to take the choice with it.
  -- Left behind, the old id names no pack: the list offers it as unknown and refuses to re-select
  -- it, and the flight is logged against an id the registry no longer has.
  if edit.originalId ~= nil and edit.originalId ~= id and selectedBatteryId() == edit.originalId then
    selectBattery(id)
  end

  ui.edit = nil
  ui.editMode = nil
  ui.editError = nil
  ui.batteryId = id
  ui.view = "battery"
  requestRebuild()
end

local function buildBatteryForm(children, x, y, w, h, i18n)
  local edit = ui.edit
  local cursorY = y

  appendLabel(children, x + 6, cursorY, w - 12,
    ui.editMode == "create" and pageText(i18n, "new_battery", "New battery")
      or pageText(i18n, "edit_battery", "Edit battery"), COLOR_THEME_PRIMARY1)
  cursorY = cursorY + 22

  if ui.editError ~= nil then
    appendLabel(children, x + 6, cursorY, w - 12, ui.editError, COLOR_THEME_WARNING)
    cursorY = cursorY + 22
  end

  cursorY = cursorY + Controls.appendTextField(children, x, cursorY, w,
    pageText(i18n, "battery_id", "Id"), {
      length = 24,
      get = function() return edit.id end,
      set = function(value) edit.id = FlightLog.sanitizeId(value) end
    })

  cursorY = cursorY + Controls.appendTextField(children, x, cursorY, w,
    pageText(i18n, "battery_name", "Name"), {
      length = 24,
      get = function() return edit.name end,
      set = function(value) edit.name = FlightLog.sanitizeName(value) end
    })

  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "battery_capacity", "Capacity"), {
      min = 0,
      max = 30000,
      -- Any whole mAh, as on the Battery page: a pack is matched against the board's profile
      -- capacities exactly, so a value this field could not hold could never match.
      suffix = " mAh",
      get = function() return math.floor(tonumber(edit.cap) or 0) end,
      set = function(value) edit.cap = math.floor(tonumber(value) or 0) end
    })

  -- Matched against a board profile's own cell count where every profile has one, which is what
  -- tells two packs of the same capacity apart; 0 leaves the field out of the file.
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "battery_cells", "Cells"), {
      min = 0,
      max = CELLS_MAX,
      get = function() return math.floor(tonumber(edit.cells) or 0) end,
      set = function(value) edit.cells = math.floor(tonumber(value) or 0) end
    })

  cursorY = cursorY + Controls.appendTextField(children, x, cursorY, w,
    pageText(i18n, "battery_models", "Models"), {
      length = 32,
      get = function() return edit.models end,
      set = function(value) edit.models = FlightLog.sanitizeModelList(value) end
    })

  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "battery_profile", "Battery profile"), {
      min = 0,
      max = PROFILE_MAX,
      get = function() return math.floor(tonumber(edit.profile) or 0) end,
      set = function(value) edit.profile = math.floor(tonumber(value) or 0) end
    })

  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "battery_cycles", "Cycles"), {
      min = 0,
      max = 9999,
      get = function() return math.floor(tonumber(edit.cycles) or 0) end,
      set = function(value) edit.cycles = math.floor(tonumber(value) or 0) end
    })

  -- The date of last use is not offered: it is a record of what happened, not a setting.
  cursorY = cursorY + 8
  appendButton(children, x + 6, cursorY, 100, 30, pageText(i18n, "save", "Save"), function()
    saveEdit(i18n)
  end)
  appendButton(children, x + 116, cursorY, 100, 30, pageText(i18n, "cancel", "Cancel"), function()
    ui.edit = nil
    ui.editMode = nil
    ui.editError = nil
    requestRebuild()
  end)
end

local function confirmDelete(entry, i18n)
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  local flights = ui.flightsByBattery[entry.id] or 0
  local message = string.format(
    pageText(i18n, "delete_message", "Remove %s from the registry? %d logged flights name it."),
    (type(entry.name) == "string" and entry.name ~= "") and entry.name or entry.id, flights)

  local function doDelete()
    local result = FlightLog.deleteBattery(entry.id)
    if result ~= true then
      ui.editError = errorText(i18n, result)
    else
      loadRegistry()
      -- Same reason as a rename: the pack for the next flight cannot be one that has just been
      -- removed from the registry.
      if selectedBatteryId() == entry.id then selectBattery(nil) end
      ui.batteryId = nil
      ui.view = "batteries"
    end
    requestRebuild()
  end

  if ConfirmDialog and type(ConfirmDialog.show) == "function" then
    ConfirmDialog.show({
      title = pageText(i18n, "delete_title", "Delete battery"),
      message = message,
      onConfirm = doDelete
    })
  else
    doDelete()
  end
end

local function buildBattery(children, x, y, w, h, i18n)
  local entry = FlightLog.findById(ui.registry, ui.batteryId)
  local cursorY = y
  if entry == nil then
    appendLabel(children, x + 10, cursorY + 20, w - 20,
      pageText(i18n, "error_notfound", "That pack is no longer in the file"), COLOR_THEME_DISABLED, CENTER)
    return
  end

  -- A pack's detail is not one of the tabs either, so it says which pack it is showing. The name
  -- is the heading and is not repeated as a row of its own; a pack that has none is headed by its
  -- id, which is what the rest of the suite calls it by anyway.
  appendLabel(children, x + 6, cursorY, w - 12,
    (type(entry.name) == "string" and entry.name ~= "") and entry.name or entry.id,
    COLOR_THEME_PRIMARY1)
  cursorY = cursorY + 22

  if ui.editError ~= nil then
    appendLabel(children, x + 6, cursorY, w - 12, ui.editError, COLOR_THEME_WARNING)
    cursorY = cursorY + 22
  end

  cursorY = cursorY + appendField(children, x, cursorY, w, pageText(i18n, "battery_id", "Id"), entry.id)
  cursorY = cursorY + appendField(children, x, cursorY, w, pageText(i18n, "battery_capacity", "Capacity"),
    entry.cap and (tostring(math.floor(entry.cap)) .. " mAh") or "-")
  cursorY = cursorY + appendField(children, x, cursorY, w, pageText(i18n, "battery_cells", "Cells"),
    (tonumber(entry.cells) or 0) >= 1 and tostring(math.floor(entry.cells)) or "-")
  cursorY = cursorY + appendField(children, x, cursorY, w, pageText(i18n, "battery_models", "Models"),
    (entry.models and #entry.models > 0) and table.concat(entry.models, ", ")
      or pageText(i18n, "models_all", "All models"))
  cursorY = cursorY + appendField(children, x, cursorY, w, pageText(i18n, "battery_profile", "Battery profile"),
    entry.profile and tostring(math.floor(entry.profile)) or "-")
  cursorY = cursorY + appendField(children, x, cursorY, w, pageText(i18n, "battery_cycles", "Cycles"),
    tostring(math.floor(entry.cycles or 0)))
  cursorY = cursorY + appendField(children, x, cursorY, w, pageText(i18n, "battery_flights", "Logged flights"),
    tostring(ui.flightsByBattery[entry.id] or 0))
  cursorY = cursorY + appendField(children, x, cursorY, w, pageText(i18n, "battery_last", "Last used"),
    (type(entry.last) == "string" and entry.last ~= "") and entry.last
      or pageText(i18n, "never_used", "Never"))

  cursorY = cursorY + 8
  appendButton(children, x + 6, cursorY, 100, 30, pageText(i18n, "edit", "Edit"), function()
    startEdit(entry)
    requestRebuild()
  end)
  appendButton(children, x + 116, cursorY, 100, 30, pageText(i18n, "delete", "Delete"), function()
    confirmDelete(entry, i18n)
  end)
end

local function buildBatteries(children, x, y, w, h, i18n)
  local cursorY = y

  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    pageText(i18n, "battery_for_next", "Battery for the next flight"),
    batteryOptions(i18n),
    selectedBatteryId() or "",
    function(value)
      selectBattery((type(value) == "string" and value ~= "") and value or nil)
      requestRebuild()
    end)

  cursorY = cursorY + 6
  appendButton(children, x + 6, cursorY, 120, 30, pageText(i18n, "new_battery", "New battery"), function()
    startEdit(nil)
    requestRebuild()
  end)
  cursorY = cursorY + 38

  if #ui.registry == 0 then
    appendLabel(children, x + 10, cursorY + 10, w - 20,
      pageText(i18n, "no_batteries", "No batteries in the registry"), COLOR_THEME_DISABLED, CENTER)
    return
  end

  local btnW = 34
  local btnX = x + w - btnW - 8
  local numW = 56
  local lastW = 92

  for i = 1, #ui.registry do
    local entry = ui.registry[i]
    appendLabel(children, x + 6, cursorY + 8, btnX - lastW - numW * 2 - 24,
      (type(entry.name) == "string" and entry.name ~= "") and entry.name or entry.id)
    appendLabel(children, btnX - lastW - numW * 2 - 12, cursorY + 8, numW,
      tostring(math.floor(entry.cycles or 0)), COLOR_THEME_DISABLED, RIGHT)
    appendLabel(children, btnX - lastW - numW - 8, cursorY + 8, numW,
      tostring(ui.flightsByBattery[entry.id] or 0), COLOR_THEME_DISABLED, RIGHT)
    appendLabel(children, btnX - lastW - 4, cursorY + 8, lastW,
      (type(entry.last) == "string" and entry.last ~= "") and entry.last or "-",
      COLOR_THEME_DISABLED, RIGHT)
    appendButton(children, btnX, cursorY + 3, btnW, 28, ">", function()
      ui.batteryId = entry.id
      ui.editError = nil
      ui.view = "battery"
      requestRebuild()
    end)
    appendDivider(children, x, cursorY + ROW_H - 1, w)
    cursorY = cursorY + ROW_H
  end
end

local function buildSettings(children, x, y, w, h, i18n)
  local cursorY = y

  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    pageText(i18n, "setting_enabled", "Write a flight log"),
    function() return ui.config.enabled == true end,
    function(value)
      ui.config.enabled = value == true
    end)

  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "setting_min_seconds", "Minimum flight length"), {
      min = 0,
      max = 600,
      step = 5,
      suffix = " s",
      get = function() return math.floor(tonumber(ui.config.min_seconds) or 30) end,
      set = function(value)
        ui.config.min_seconds = math.floor(tonumber(value) or 30)
      end
    })

  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    pageText(i18n, "setting_ask_on_connect", "Ask which pack after connecting"),
    function() return ui.config.ask_on_connect == true end,
    function(value)
      ui.config.ask_on_connect = value == true
    end)

  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    pageText(i18n, "setting_set_fc_profile", "Set the pack's battery profile"),
    function() return ui.config.set_fc_profile == true end,
    function(value)
      ui.config.set_fc_profile = value == true
    end)

  cursorY = cursorY + 8
  appendLabel(children, x + 6, cursorY, w - 12, FlightLog.dataPath(), COLOR_THEME_DISABLED)
end

function M.build(ctx)
  ensureDeps()
  ui.requestRebuild = ctx and ctx.requestRebuild or nil
  ensureLoaded(ctx and ctx.preferences)

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h or 200
  local i18n = ctx.i18n

  if ui.loading then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = pageText(i18n, "loading_title", "Loading"),
      message = pageText(i18n, "loading_message", "Reading the flight log"),
      progress = 0.3
    })
    return
  end

  -- The editor is the whole page while it is open, and the tab row is left out of it: one press
  -- on a tab throws the form away, and a pack half typed in is not something to lose to the press
  -- that was meant to move the cursor. Back cancels the form, which is the way out of it.
  local formOpen = ui.edit ~= nil
  local bodyY = formOpen and y or (y + TAB_ROW_H + TAB_ROW_GAP)
  local bodyH = h - (bodyY - y)

  if formOpen then
    buildBatteryForm(children, x, bodyY, w, bodyH, i18n)
  elseif ui.view == "flight" then
    buildFlight(children, x, bodyY, w, bodyH, i18n)
  elseif ui.view == "models" then
    buildModels(children, x, bodyY, w, bodyH, i18n)
  elseif ui.view == "battery" then
    buildBattery(children, x, bodyY, w, bodyH, i18n)
  elseif ui.view == "batteries" then
    buildBatteries(children, x, bodyY, w, bodyH, i18n)
  elseif ui.view == "settings" then
    buildSettings(children, x, bodyY, w, bodyH, i18n)
  else
    buildFlights(children, x, bodyY, w, bodyH, i18n)
  end

  -- Appended last although it is drawn first, and the order is what matters rather than the
  -- position. A build hands its children to lvgl.build in order, each focusable object joins the
  -- keypad group as it is created, and LVGL focuses the first object to enter an empty group --
  -- which every rebuild produces, because the previous scene is cleared. A tab row appended first
  -- therefore takes the focus ring on every rebuild, whatever the body below it is for.
  if not formOpen then
    appendTabs(children, x, y, w, i18n)
  end
end

return M
