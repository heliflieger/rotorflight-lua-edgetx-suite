-- EdgeTX MSP API: governor_profile (ported from Ethos)

local Api = {
  command = 148,
  writeCommand = 149,
  simulatorResponse = {
    -- Rotorflight Ethos >=12.0.9 layout
    208, 7, -- governor_headspeed (2000)
    100,    -- governor_gain
    10,     -- governor_p_gain
    125,    -- governor_i_gain
    5,      -- governor_d_gain
    20,     -- governor_f_gain
    0,      -- governor_tta_gain
    20,     -- governor_tta_limit
    10,     -- governor_yaw_weight
    40,     -- governor_cyclic_weight
    100,    -- governor_collective_weight
    100,    -- governor_max_throttle
    10,     -- governor_min_throttle
    10,     -- governor_fallback_drop
    251, 3  -- governor_flags (U16)
  }
}

local function to_u16(lo, hi)
  lo = tonumber(lo) or 0
  hi = tonumber(hi) or 0
  return ((hi & 0xFF) << 8) | (lo & 0xFF)
end

local function from_u16(v)
  v = math.floor(tonumber(v) or 0) & 0xFFFF
  return v & 0xFF, (v >> 8) & 0xFF
end

function Api.parse(buf)
  if type(buf) ~= "table" then return nil end
  local n = #buf
  local i = 1
  local out = {}

  if n >= 17 then
    out.governor_headspeed = to_u16(buf[i], buf[i+1]); i = i + 2
    out.governor_gain = tonumber(buf[i]); i = i + 1
    out.governor_p_gain = tonumber(buf[i]); i = i + 1
    out.governor_i_gain = tonumber(buf[i]); i = i + 1
    out.governor_d_gain = tonumber(buf[i]); i = i + 1
    out.governor_f_gain = tonumber(buf[i]); i = i + 1
    out.governor_tta_gain = tonumber(buf[i]); i = i + 1
    out.governor_tta_limit = tonumber(buf[i]); i = i + 1
    out.governor_yaw_weight = tonumber(buf[i]); i = i + 1
    out.governor_cyclic_weight = tonumber(buf[i]); i = i + 1
    out.governor_collective_weight = tonumber(buf[i]); i = i + 1
    out.governor_max_throttle = tonumber(buf[i]); i = i + 1
    out.governor_min_throttle = tonumber(buf[i]); i = i + 1
    out.governor_fallback_drop = tonumber(buf[i]); i = i + 1
    out.governor_flags = to_u16(buf[i], buf[i+1]); i = i + 2

  elseif n >= 14 then
    -- older layout
    out.governor_headspeed = to_u16(buf[i], buf[i+1]); i = i + 2
    out.governor_gain = tonumber(buf[i]); i = i + 1
    out.governor_p_gain = tonumber(buf[i]); i = i + 1
    out.governor_i_gain = tonumber(buf[i]); i = i + 1
    out.governor_d_gain = tonumber(buf[i]); i = i + 1
    out.governor_f_gain = tonumber(buf[i]); i = i + 1
    out.governor_tta_gain = tonumber(buf[i]); i = i + 1
    out.governor_tta_limit = tonumber(buf[i]); i = i + 1
    out.governor_yaw_ff_weight = tonumber(buf[i]); i = i + 1
    out.governor_cyclic_ff_weight = tonumber(buf[i]); i = i + 1
    out.governor_collective_ff_weight = tonumber(buf[i]); i = i + 1
    out.governor_max_throttle = tonumber(buf[i]); i = i + 1
    out.governor_min_throttle = tonumber(buf[i]); i = i + 1
  else
    return nil
  end

  return out
end

function Api.buildWritePayload(data)
  if type(data) ~= "table" then return nil end

  local headspeed = tonumber(data.governor_headspeed)
  local gain = tonumber(data.governor_gain)
  local p_gain = tonumber(data.governor_p_gain)
  local i_gain = tonumber(data.governor_i_gain)
  local d_gain = tonumber(data.governor_d_gain)
  local f_gain = tonumber(data.governor_f_gain)
  local tta_gain = tonumber(data.governor_tta_gain)
  local tta_limit = tonumber(data.governor_tta_limit)
  local yaw_w = tonumber(data.governor_yaw_weight or data.governor_yaw_ff_weight)
  local cyc_w = tonumber(data.governor_cyclic_weight or data.governor_cyclic_ff_weight)
  local col_w = tonumber(data.governor_collective_weight or data.governor_collective_ff_weight)
  local max_th = tonumber(data.governor_max_throttle)
  local min_th = tonumber(data.governor_min_throttle)
  local fallback_drop = tonumber(data.governor_fallback_drop)
  local flags = tonumber(data.governor_flags)

  -- 13 fields required by both layouts
  if headspeed == nil or gain == nil or p_gain == nil or i_gain == nil or
     d_gain == nil or f_gain == nil or tta_gain == nil or tta_limit == nil or
     yaw_w == nil or cyc_w == nil or col_w == nil or max_th == nil or
     min_th == nil then
    return nil
  end

  local p = {}
  local function push(v) p[#p+1] = v end

  local lo, hi = from_u16(headspeed)
  push(lo); push(hi)
  push(math.floor(gain) & 0xFF)
  push(math.floor(p_gain) & 0xFF)
  push(math.floor(i_gain) & 0xFF)
  push(math.floor(d_gain) & 0xFF)
  push(math.floor(f_gain) & 0xFF)
  push(math.floor(tta_gain) & 0xFF)
  push(math.floor(tta_limit) & 0xFF)
  push(math.floor(yaw_w) & 0xFF)
  push(math.floor(cyc_w) & 0xFF)
  push(math.floor(col_w) & 0xFF)
  push(math.floor(max_th) & 0xFF)
  push(math.floor(min_th) & 0xFF)

  -- 17-byte layout only when the profile carried the extra fields;
  -- otherwise emit the 14-byte record the profile was read as.
  if fallback_drop == nil or flags == nil then
    return p
  end
  push(math.floor(fallback_drop) & 0xFF)
  lo, hi = from_u16(flags)
  push(lo); push(hi)

  return p
end

return Api
