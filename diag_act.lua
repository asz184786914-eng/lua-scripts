-- 激活码诊断：对比保存指纹 vs 当前指纹
local _0k = "xy435116694754"

-- XOR
local function _xc(a, b)
    local r = ""
    for i = 1, #a do r = r .. string.char(string.byte(a, i) ~ string.byte(b, (i - 1) % #b + 1)) end
    return r
end

-- hex解码
local function _fh(h)
    local s = ""
    h = h:match("^%s*(.-)%s*$") -- 去首尾空白
    for i = 1, #h - 1, 2 do
        local byte = tonumber(h:sub(i, i + 1), 16)
        if not byte then return nil, "hex error at pos " .. i end
        s = s .. string.char(byte)
    end
    return s
end

-- 读文件
local f = io.open("/sdcard/.unity_key", "r")
if not f then
    gg.alert("❌ /sdcard/.unity_key 不存在")
    return
end
local encoded = f:read("*a")
f:close()
encoded = encoded:match("^%s*(.-)%s*$") -- 去空白

-- 解码
local raw, err = _fh(encoded)
if not raw then
    gg.alert("❌ hex解码失败: " .. tostring(err) .. "\n\n原始数据:\n" .. encoded)
    return
end
local decoded = _xc(raw, _0k)
local savedFP = decoded:match("^(.+)|")
local savedKey = decoded:match("|(.+)$")

gg.alert("保存的数据:\n指纹: [" .. (savedFP or "nil") .. "]\n激活码: [" .. (savedKey or "nil") .. "]")

-- 当前指纹（和主脚本相同逻辑）
local ids = {}
local c

f = io.open("/proc/cmdline", "r")
if f then
    c = f:read("*a"); f:close()
    local s = c:match("androidboot%.serialno=(%S+)") or c:match("serialno=(%S+)")
    if s then ids[#ids + 1] = s:gsub("[,;\"]", "") end
end

f = io.open("/proc/cpuinfo", "r")
if f then
    c = f:read("*a"); f:close()
    local hw = c:match("Hardware%s*:%s*(.-)\n")
    local s = c:match("Serial%s*:%s*(%S+)")
    if hw then ids[#ids + 1] = hw:gsub("%s+$", "") end
    if s and s ~= "0000000000000000" then ids[#ids + 1] = s end
end

f = io.open("/sys/devices/soc0/serial_number", "r")
if f then c = f:read("*a"):gsub("%s", ""); f:close(); if c ~= "" then ids[#ids + 1] = c end end

f = io.open("/sys/devices/soc0/machine", "r")
if f then c = f:read("*a"):gsub("%s", ""); f:close(); if c ~= "" then ids[#ids + 1] = c end end

local currentFP = table.concat(ids, "|")
if currentFP == "" then currentFP = "default_device" end

gg.alert("当前指纹:\n[" .. currentFP .. "]\n\n保存指纹:\n[" .. (savedFP or "nil") .. "]\n\n一致: " .. tostring(currentFP == savedFP))
