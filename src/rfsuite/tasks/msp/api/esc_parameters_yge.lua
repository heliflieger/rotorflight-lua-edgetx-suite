-- Ported ESC_PARAMETERS_YGE -> esc_parameters_yge.lua
local Api = {
    command = 217,
    writeCommand = 218,
    mspSignature = 0xA5,
    mspHeaderBytes = 2
}

local FIELD_SPEC = {
    {"esc_signature","U8"}, {"esc_command","U8"}, {"esc_model","U8"}, {"esc_version","U8"},
    {"governor","U16"}, {"lv_bec_voltage","U16"}, {"timing","U16"}, {"acceleration","U16"},
    {"gov_p","U16"}, {"gov_i","U16"}, {"throttle_response","U16"}, {"auto_restart_time","U16"},
    {"cell_cutoff","U16"}, {"active_freewheel","U16"}, {"esc_type","U16"}, {"firmware_version","U32"},
    {"serial_number","U32"}, {"unknown_1","U16"}, {"stick_zero_us","U16"}, {"stick_range_us","U16"},
    {"unknown_2","U16"}, {"motor_poll_pairs","U16"}, {"pinion_teeth","U16"}, {"main_teeth","U16"},
    {"min_start_power","U16"}, {"max_start_power","U16"}, {"unknown_3","U16"}, {"flags","U8"},
    {"unknown_4","U8"}, {"current_limit","U16"},
    -- The last eight bytes of the block. Their meaning is unknown here, as it is in the older
    -- suite this layout comes from -- but they are part of what the ESC sends and of what it
    -- expects back. The firmware sizes the payload as 2 + 2 * N from the parameter count the
    -- ESC reports in the first U16, and this fixture reports 32, so the block is 66 bytes.
    -- Without these a write is eight bytes short and the firmware reads past its end.
    {"unknown_5","U32"}, {"unknown_6","U32"}
}

-- 66 bytes, matching the field spec above. The previous fixture was 52: it left three U16s out
-- of the middle of the block -- startup response, cutoff cell voltage and active freewheel --
-- so every field from `acceleration` onwards decoded the value belonging to a later one.
-- `auto_restart_time` came out as 848, which is the esc_type, and `cell_cutoff` as 38019,
-- which is half of a firmware version.
local SIM_RESPONSE = {
    165,0,  32,0,  3,0,  55,0,  0,0,  0,0,  4,0,  3,0,  1,0,  1,0,  2,0,  3,0,  80,3,
    131,148,1,0,  30,170,0,0,
    3,0,  86,4,  22,3,  163,15,  1,0,  2,0,  2,0,  20,0,  20,0,  0,0,
    0,  0,  2,19,
    2,0,20,0,  22,0,0,0
}

local TYPE_LEN = {U8=1,S8=1,U16=2,S16=2,U24=3,U32=4,U64=8,U120=15,U128=16}

local function has_big_flag(field)
    for _, v in ipairs(field) do if v == "big" then return true end end
    return false
end

local function read_unsigned(buf,pos,len,big)
    local v=0
    if big then for i=0,len-1 do v=v*256+(tonumber(buf[pos+i]) or 0) end
    else local mul=1; for i=0,len-1 do v=v+(tonumber(buf[pos+i]) or 0)*mul; mul=mul*256 end end
    return v
end

local function read_signed(buf,pos,len,big)
    local v=read_unsigned(buf,pos,len,big)
    local max=2^(len*8); local half=2^(len*8-1)
    if v>=half then v=v-max end; return v
end

local function bytes_to_string(buf,pos,len)
    local chars={}
    for i=0,len-1 do chars[#chars+1]=string.char(tonumber(buf[pos+i]) or 0) end
    local s=table.concat(chars)
    s=string.gsub(s, '%z+$','')
    s=string.gsub(s, '%s+$','')
    return s
end

local function pack_unsigned(v,len,big)
    v=tonumber(v) or 0; local out={}
    if big then for i=len-1,0,-1 do out[#out+1]=math.floor(v/(256^i))%256 end
    else for i=0,len-1 do out[#out+1]=math.floor(v/(256^i))%256 end end
    return out
end

local function pack_string(s,len)
    s=s or ''; local out={}
    for i=1,len do out[#out+1]=string.byte(s, i) or 0 end; return out
end

Api.fields = FIELD_SPEC
Api.simulatorResponse = SIM_RESPONSE

function Api.parse(buf)
    if type(buf)~='table' then return nil end
    local pos=1; local out={}
    for _, f in ipairs(FIELD_SPEC) do
        local name, typ = f[1], f[2]
        local len = TYPE_LEN[typ] or 1; local big = has_big_flag(f)
        if typ=='U120' or typ=='U128' then out[name]=bytes_to_string(buf,pos,len); pos=pos+len
        elseif string.sub(typ, 1, 1)=='S' then out[name]=read_signed(buf,pos,len,big); pos=pos+len
        else out[name]=read_unsigned(buf,pos,len,big); pos=pos+len end
    end
    return out
end

function Api.buildWritePayload(data)
    data=data or {}; local payload={}
    for _, f in ipairs(FIELD_SPEC) do
        local name, typ = f[1], f[2]; local len = TYPE_LEN[typ] or 1; local big = has_big_flag(f)
        local v = data[name]
        if typ=='U120' or typ=='U128' then local b=pack_string(v,len); for _,x in ipairs(b) do payload[#payload+1]=x end
        else local b=pack_unsigned(v or 0,len,big); for _,x in ipairs(b) do payload[#payload+1]=x end end
    end
    return payload
end

return Api
