-- The consumption reserve, in one place: where the number comes from, what an out-of-band
-- value becomes, and how a raw fuel reading is rescaled above it.
--
-- The reserve is the percentage of the pack that SmartFuel treats as unavailable, so a fuel
-- reading of `reserve` means zero usable fuel and 100 stays 100. Producer and diagnostic must
-- resolve it identically or the page that exists to explain the sensor disagrees with it.
local M = {}

M.RESERVE_MIN = 15
M.RESERVE_MAX = 60
M.RESERVE_DEFAULT = 35

--- Where the number comes from: the per-model preference wins over the flight controller's
-- `cbat_alert_percent`. Returns the raw value, or nil when neither side holds one; the
-- out-of-band rule is the caller's, because the editor clamps where the sensor substitutes.
function M.pick(session, batteryConfig)
  local batteryPrefs = session and session.modelPreferences and session.modelPreferences.battery or nil
  local reserve = batteryPrefs and batteryPrefs.consumption_warning_percentage
  if reserve == nil then
    reserve = batteryConfig and batteryConfig.consumptionWarningPercentage
  end
  return reserve
end

--- What the SENSOR does with a value it cannot use: substitute the default rather than clamp
-- into the band, so a nonsensical reserve does not silently become a plausible one.
function M.sanitize(value)
  local reserve = tonumber(value)
  if reserve == nil then return M.RESERVE_DEFAULT end
  reserve = math.floor(reserve + 0.5)
  if reserve < M.RESERVE_MIN or reserve > M.RESERVE_MAX then
    return M.RESERVE_DEFAULT
  end
  return reserve
end

--- The number the sensor is computed with. Pure: it reads the session and writes nothing.
function M.resolve(session, batteryConfig)
  return M.sanitize(M.pick(session, batteryConfig))
end

--- Rescale a raw 0..100 reading so that `warningPercent` reads 0 and 100 still reads 100.
-- Below the reserve the result clamps to 0 rather than going negative.
function M.applyPercent(value, warningPercent)
  if type(value) ~= "number" then return nil end
  local fuel = value
  if fuel < 0 then fuel = 0 elseif fuel > 100 then fuel = 100 end
  local warning = tonumber(warningPercent) or 0
  if warning < 0 then warning = 0 elseif warning > 99 then warning = 99 end
  if warning > 0 then
    fuel = (fuel - warning) * 100 / (100 - warning)
  end
  if fuel < 0 then fuel = 0 elseif fuel > 100 then fuel = 100 end
  return fuel
end

return M
