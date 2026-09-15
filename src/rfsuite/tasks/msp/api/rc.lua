-- EdgeTX MSP API: RC (live channel values)
--
-- One U16 per channel, in microseconds, and the order is the flight controller's own function
-- order -- roll, pitch, yaw, collective, throttle, then the aux channels -- because the reply is
-- serialised from the values the channel map has already sorted. It is therefore not the order
-- the channels arrive in on the wire; MSP_RX_MAP is what relates the two.
--
-- The reply carries no count of its own: its length is the number of channels the receiver
-- delivers, so a channel is present exactly when two more bytes are.

local Api = {
  command = 105, -- MSP_RC
  simulatorResponse = {
    220, 5, -- aileron    1500
    220, 5, -- elevator   1500
    220, 5, -- rudder     1500
    220, 5, -- collective 1500
    232, 3, -- throttle   1000
    232, 3, -- aux1       1000
    220, 5, -- aux2       1500
    220, 5, -- aux3       1500
    220, 5, -- aux4       1500
    220, 5, -- aux5       1500
    220, 5, -- aux6       1500
    220, 5, -- aux7       1500
    220, 5, -- aux8       1500
    220, 5, -- aux9       1500
    220, 5, -- aux10      1500
    220, 5  -- aux11      1500
  }
}

-- The names the firmware gives the channels ahead of the aux block, in its own order.
local CONTROL_CHANNELS = { "aileron", "elevator", "rudder", "collective", "throttle" }

-- MAX_SUPPORTED_RC_CHANNEL_COUNT. A longer reply than this cannot have come from the flight
-- controller, so the surplus is dropped rather than named.
local MAX_CHANNELS = 18

local function parseU16(lo, hi)
  return ((tonumber(hi) or 0) << 8) | (tonumber(lo) or 0)
end

function Api.parse(buf)
  if type(buf) ~= "table" or #buf < 2 then return nil end

  local count = math.floor(#buf / 2)
  if count > MAX_CHANNELS then count = MAX_CHANNELS end

  local channels = {}
  local out = { channels = channels, channel_count = count }

  for i = 1, count do
    local value = parseU16(buf[i * 2 - 1], buf[i * 2])
    channels[i] = value
    if CONTROL_CHANNELS[i] then
      out[CONTROL_CHANNELS[i]] = value
    else
      out["aux" .. (i - #CONTROL_CHANNELS)] = value
    end
  end

  return out
end

return Api
