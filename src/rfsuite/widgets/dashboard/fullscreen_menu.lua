local M = {}

local requireModule = (_G.rfsuite and _G.rfsuite.require) or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or ("/SCRIPTS/TOOLS/rfsuite-core/" .. path)
  local chunk = loadScript(fullPath, "t")
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

function M.build(children, widget)
  local dW = widget.zone.w
  local dH = widget.zone.h
  local dX = 0
  local dY = 0
  
  local t = (widget.i18n and type(widget.i18n.t) == "function") and widget.i18n.t or function(k, f) return f or k end

  local bg_color = COLOR_THEME_PRIMARY3 or BLACK
  if bg_color == BLACK and lcd and type(lcd.RGB) == "function" then
     bg_color = lcd.RGB(40, 40, 40)
  end
  local accent_color = COLOR_THEME_SECONDARY1 or WHITE
  local btn_color = COLOR_THEME_PRIMARY1 or DARKGREY
  
  -- 1. Full Background
  children[#children+1] = {
    type = "rectangle", x=dX, y=dY, w=dW, h=dH, color=bg_color, filled=true
  }

  -- Layout Profile Definition
  -- TX16S MK3 is 800x480 (dH ~480)
  -- Standard TX16S is 480x272 (dH ~272)
  local isLarge = dH > 350
  
  local headerH, titleFont, fontH, closeSize, contentGap, titleGap, btnH, gapY, paddingX
  local headTextOffY, closeTextOffY, btnTextOffY

  if isLarge then
    -- Layout for TX16S MK3 (Large High-Res)
    headerH = 60
    titleFont = MIDSIZE
    fontH = 24
    closeSize = 44
    contentGap = 20
    titleGap = fontH + 30
    btnH = 50
    gapY = 10
    paddingX = 15
    headTextOffY = -6
    closeTextOffY = -8
    btnTextOffY = -8
  else
    -- Layout for standard TX16S (480x272)
    headerH = 22
    titleFont = SMLSIZE
    fontH = 12
    closeSize = 20
    contentGap = 5
    titleGap = fontH + 10
    btnH = 28
    gapY = 8
    paddingX = 5
    headTextOffY = -2
    closeTextOffY = -4
    btnTextOffY = -4
  end

  -- 2. Header
  children[#children+1] = {
    type = "rectangle", x=dX, y=dY, w=dW, h=headerH, color=btn_color, filled=true
  }
  
  children[#children+1] = {
    type = "label", x=dX + paddingX, y=dY + math.floor((headerH - fontH)/2) + headTextOffY, w=dW-60, 
    text=t("widgets.dashboard.quick_settings", "QUICK SETTINGS"), color=WHITE, align=LEFT, font=titleFont
  }
  
  -- 3. Close Button (X)
  local cx = dX + dW - closeSize - (isLarge and 8 or 1)
  local cy = dY + math.floor((headerH - closeSize)/2)
  
  children[#children+1] = {
    type = "button", x=cx, y=cy, w=closeSize, h=closeSize, color=COLOR_THEME_SECONDARY1 or RED,
    press = function()
      widget.built = false
      widget.renderKey = nil
      if lcd and type(lcd.exitFullScreen) == "function" then
         lcd.exitFullScreen()
      end
    end
  }
  
  children[#children+1] = {
    type = "label", x=cx, y=cy + math.floor((closeSize - fontH)/2) + closeTextOffY, w=closeSize, text="X", color=WHITE, align=CENTER, font=titleFont
  }
  
  -- 4. Content Area
  local contentY = dY + headerH + contentGap

  -- 4a. Erase Blackbox Button
  local eraseBtnW = math.floor(dW - paddingX * 2)
  children[#children+1] = {
    type = "button", x=dX + paddingX, y=contentY, w=eraseBtnW, h=btnH, color=btn_color,
    press = function()
         local mspModule = requireModule("tasks/msp/runtime.lua")
         if mspModule and mspModule.getState then
            local mState = mspModule.getState()
            if mState and mState.queue then
               local eraseApi = requireModule("tasks/msp/api/dataflash_erase.lua")
               local summaryApi = requireModule("tasks/msp/api/dataflash_summary.lua")
               
               if eraseApi and summaryApi then
                 mState.queue:add({
                    command = eraseApi.writeCommand,
                    payload = eraseApi.buildWritePayload({}),
                    simulatorResponse = {},
                    isWrite = true,
                    timeout = 10.0,
                 })
                 mState.queue:add({
                    command = summaryApi.command,
                    simulatorResponse = summaryApi.simulatorResponse,
                    processReply = function(_, buf)
                      local stats = summaryApi.parse(buf)
                      if stats then
                        if type(_G) == "table" and _G.rfsuite and _G.rfsuite.session then
                          _G.rfsuite.session.dataflash = stats
                        end
                      end
                    end
                 })
               end
            end
         end
         
         widget.built = false
         widget.renderKey = nil
         if lcd and type(lcd.exitFullScreen) == "function" then
            lcd.exitFullScreen()
         end
    end
  }
  local eraseTextY = contentY + math.floor((btnH - fontH)/2) + btnTextOffY
  children[#children+1] = {
    type = "label", x=dX + paddingX, y=eraseTextY, w=eraseBtnW, 
    text=t("widgets.dashboard.erase_blackbox", "ERASE BLACKBOX"), color=WHITE, align=CENTER, font=titleFont
  }

  contentY = contentY + btnH + titleGap
  
  -- 4b. Battery Profile Section Title
  children[#children+1] = {
    type = "label", x=dX + paddingX, y=contentY, w=dW-(paddingX*2), 
    text=t("widgets.dashboard.battery_profile", "BATTERY PROFILE"), color=WHITE, align=LEFT, font=titleFont
  }
  
  local listY = contentY + titleGap
  
  local caps = {}
  if widget.state.battery_config then
    for i=0,5 do
      if (widget.state.battery_config["batteryCapacity_"..i] or 0) > 0 then
        caps[#caps+1] = { index = i, cap = widget.state.battery_config["batteryCapacity_"..i] }
      end
    end
  end
  
  local cols = 2
  if dW < 200 then cols = 1 end
  local btnW = math.floor((dW - paddingX*(cols+1)) / cols)
  
  for i, c in ipairs(caps) do
     local row = math.floor((i-1)/cols)
     local col = (i-1)%cols
     local bx = dX + paddingX + col*(btnW+paddingX)
     local by = listY + row*(btnH+gapY)
     
     if by + btnH > dY + dH then break end
     
     -- Highlight active battery profile
     -- FIX: Telemetry sensor BatP is 1-based (1 to 6)
     local isCurrent = (widget.state.batteryProfile == (c.index + 1))
     local bColor = isCurrent and accent_color or btn_color
     local tColor = isCurrent and BLACK or WHITE
     
     -- Button (Interactive layer)
     children[#children+1] = {
       type = "button", x=bx, y=by, w=btnW, h=btnH, color=bColor,
        press = function()
          local mspModule = requireModule("tasks/msp/runtime.lua")
          if mspModule and mspModule.getState then
            local mState = mspModule.getState()
            if mState and mState.queue then
               -- 1. Set Battery Profile
               local api = requireModule("tasks/msp/api/battery_profile.lua")
               if api and type(api.buildWritePayload) == "function" then
                 mState.queue:add({
                    command = api.writeCommand,
                    payload = api.buildWritePayload({ batteryProfile = c.index }),
                    simulatorResponse = {}
                 })
               end
               -- 2. Save to EEPROM so the FC applies and broadcasts the change
               local eepromApi = requireModule("tasks/msp/api/eeprom_write.lua")
               if eepromApi and type(eepromApi.buildWritePayload) == "function" then
                 mState.queue:add({
                    command = eepromApi.writeCommand,
                    payload = eepromApi.buildWritePayload({}),
                    simulatorResponse = {},
                    isWrite = true,
                 })
               end
            end
          end

          -- Close after selection
          widget.built = false
          widget.renderKey = nil
          if lcd and type(lcd.exitFullScreen) == "function" then
             lcd.exitFullScreen()
          end
        end
     }
     
     -- Label (visual only)
     local textY = by + math.floor((btnH - fontH)/2) + btnTextOffY
     children[#children+1] = {
       type = "label", x=bx, y=textY, w=btnW, text=tostring(c.cap).." mAh", color=tColor, align=CENTER, font=titleFont
     }
  end

end

return M
