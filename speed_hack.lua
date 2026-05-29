-- ============================================================
-- ╔══════════════════════════════════════════════╗
-- ║   Unity Time.timeScale 加速器 v5.2.4          ║
-- ║   设备绑定激活 + 防篡改 + 云端更新           ║
-- ║   署名: xy435116694754                      ║
-- ╚══════════════════════════════════════════════╝
-- ============================================================

-- ============ 基础工具函数 ============

local function _bx(a, b)
    local r, m = 0, 1
    for _ = 1, 8 do
        if (a % 2) ~= (b % 2) then r = r + m end
        m = m * 2; a = math.floor(a / 2); b = math.floor(b / 2)
    end
    return r
end

local function _xc(s, k)
    local r = {}
    for i = 1, #s do
        r[i] = string.char(_bx(string.byte(s, i), string.byte(k, (i - 1) % #k + 1)))
    end
    return table.concat(r)
end

local function _fh(s)
    local r = {}
    for i = 1, #s, 2 do
        r[#r + 1] = string.char(tonumber(s:sub(i, i + 1), 16))
    end
    return table.concat(r)
end

local function _xor32(a, b)
    local r, m = 0, 1
    for _ = 1, 32 do
        if (a % 2) ~= (b % 2) then r = r + m end
        m = m * 2; a = math.floor(a / 2); b = math.floor(b / 2)
    end
    return r
end

local function _fnv1a(s, seed)
    local h = seed or 0x811c9dc5
    for i = 1, #s do
        h = _xor32(h, string.byte(s, i))
        h = (h * 16777619) % 4294967296
    end
    return h
end

-- ============ Base32 编解码 ============

local _B32 = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

local function _b32enc(data)
    local result, bits, val = {}, 0, 0
    for i = 1, #data do
        val = val * 256 + string.byte(data, i)
        bits = bits + 8
        while bits >= 5 do
            bits = bits - 5
            local idx = math.floor(val / (2 ^ bits)) % 32 + 1
            result[#result + 1] = _B32:sub(idx, idx)
            val = val % (2 ^ bits)
        end
    end
    if bits > 0 then
        local idx = val * (2 ^ (5 - bits)) + 1
        if idx >= 1 and idx <= #_B32 then
            result[#result + 1] = _B32:sub(idx, idx)
        end
    end
    return table.concat(result)
end

local function _b32dec(s)
    local result, bits, val = {}, 0, 0
    for i = 1, #s do
        local c = s:sub(i, i):upper()
        local idx = _B32:find(c, 1, true)
        if idx then
            val = val * 32 + (idx - 1)
            bits = bits + 5
            while bits >= 8 do
                bits = bits - 8
                result[#result + 1] = string.char(math.floor(val / (2 ^ bits)) % 256)
                val = val % (2 ^ bits)
            end
        end
    end
    return table.concat(result)
end

local function _fmtCode(s, g)
    g = g or 4
    local r = {}
    for i = 1, #s, g do
        r[#r + 1] = s:sub(i, i + g - 1)
    end
    return table.concat(r, "-")
end

-- ============ 主密钥与激活状态 ============

local _0k = "xy435116694754"
local _0t = nil
local _0v = false

-- ============ 设备指纹哈希 ============

local function _fpHash(fp_str)
    local h1 = _fnv1a(fp_str, 0x811c9dc5)
    local h2 = _fnv1a(fp_str, 0x1234abcd)
    local b = ""
    local v = h1
    for _ = 1, 4 do
        b = b .. string.char(v % 256)
        v = math.floor(v / 256)
    end
    b = b .. string.char(h2 % 256)
    return b
end

-- ============ 激活码哈希 ============

local function _actHash(fp_hex)
    local _as = _xc(_fh("2b095156517950555d0b0405006c21"), _0k)
    local actInput = fp_hex .. _as
    local ah1 = _fnv1a(actInput, 0x5678ef01)
    local ah2 = _fnv1a(actInput, 0x9abcdef0)
    local ah3 = _fnv1a(actInput, 0x13579bdf)
    local b = ""
    for _, h in ipairs({ah1, ah2, ah3}) do
        local v = h
        for _ = 1, 4 do
            b = b .. string.char(v % 256)
            v = math.floor(v / 256)
        end
    end
    return b:sub(1, 10)
end

-- ============ 设备指纹采集 ============

local function _getDeviceFP()
    local ids = {}
    local f, c

    f = io.open("/proc/cmdline", "r")
    if f then
        c = f:read("*a"); f:close()
        local s = c:match("androidboot%.serialno=(%S+)")
            or c:match("serialno=(%S+)")
        if s then
            s = s:gsub("[,;\"]", "")
            ids[#ids + 1] = s
        end
    end

    f = io.open("/proc/cpuinfo", "r")
    if f then
        c = f:read("*a"); f:close()
        local hw = c:match("Hardware%s*:%s*(.-)\n")
        local s = c:match("Serial%s*:%s*(%S+)")
        if hw then
            hw = hw:gsub("%s+$", "")
            ids[#ids + 1] = hw
        end
        if s and s ~= "0000000000000000" then
            ids[#ids + 1] = s
        end
    end

    f = io.open("/sys/devices/soc0/serial_number", "r")
    if f then
        c = f:read("*a"):gsub("%s", "")
        f:close()
        if c ~= "" then ids[#ids + 1] = c end
    end

    f = io.open("/sys/devices/soc0/machine", "r")
    if f then
        c = f:read("*a"):gsub("%s", "")
        f:close()
        if c ~= "" then ids[#ids + 1] = c end
    end

    local raw = table.concat(ids, "|")
    if raw == "" then raw = (gg.getSelectedPackage() or "unknown") end
    return raw
end

-- ============ 设备码生成 ============

local function _getDeviceCode()
    local fp = _getDeviceFP()
    local h = _fpHash(fp)
    local encrypted = _xc(h, _0k:sub(1, 5))
    local code = _b32enc(encrypted)
    return _fmtCode(code:sub(1, 8))
end

-- ============ 激活码验证 ============

local function _verifyKey(actKey)
    if not actKey or actKey == "" then return false end
    actKey = actKey:upper():gsub("[%s%-]", "")
    if #actKey ~= 16 then return false end

    local fp = _getDeviceFP()
    local fpH = _fpHash(fp)
    local fpHex = ""
    for i = 1, #fpH do
        fpHex = fpHex .. string.format("%02x", string.byte(fpH, i))
    end

    local expectedH = _actHash(fpHex)
    local expectedEnc = _xc(expectedH, _0k:sub(1, 10))
    local expectedCode = _b32enc(expectedEnc):sub(1, 16)

    return actKey == expectedCode
end

-- ============ 受保护字符串解码 ============

local function _ds(hex_str)
    if not _0t then return nil end
    local key = _0t .. _0k
    local raw = _fh(hex_str)
    return _xc(raw, key)
end

local _P = {
    search_val = "1c1948",
    author     = "554e4c4f434b494f020a01060402",
    app_name   = "785911080f9ff2d9ddb3aad4a89e",
    time_scale = "795e15192519191551",
    unity_tag  = "785911080f9ff2d9ddb3aad4a89e164f0119071a19",
    about_info = "785911080f9ff2d9ddb3aad4a89e164f01",
}

local function _gs(key)
    local v = _ds(_P[key])
    if not v then
        return "ERR_" .. tostring(math.random(1000, 9999))
    end
    return v
end

-- ============ 本地激活保存（多路存储）============

local _SAVE_PATH = "/sdcard/.unity_key"
local _SAVE_TAG = "unity_act"  -- gg.saveVariable 的 key

local function _encodeActivation(actKey)
    local fp = _getDeviceFP()
    local data = fp .. "|" .. actKey
    local encoded = ""
    for i = 1, #data do
        encoded = encoded .. string.format("%02x", _bx(string.byte(data, i), string.byte(_0k, (i - 1) % #_0k + 1)))
    end
    return encoded
end

local function _decodeActivation(encoded)
    if not encoded or encoded == "" then return nil end
    local raw = _fh(encoded)
    local decoded = _xc(raw, _0k)
    local savedFP = decoded:match("^(.+)|")
    local savedKey = decoded:match("|(.+)$")
    if not savedFP or not savedKey then return nil end
    local currentFP = _getDeviceFP()
    if savedFP ~= currentFP then return nil end
    return savedKey
end

local function _saveActivation(actKey)
    local encoded = _encodeActivation(actKey)
    local saved = false

    -- 方式1: 固定路径 /sdcard/.unity_key
    local f = io.open(_SAVE_PATH, "w")
    if f then
        f:write(encoded)
        f:close()
        saved = true
    end

    -- 方式2: 脚本同目录
    if not saved then
        local ok, scriptPath = pcall(gg.getFile)
        if ok and scriptPath then
            local dir = scriptPath:match("(.*/)")
            if dir then
                f = io.open(dir .. ".unity_key", "w")
                if f then
                    f:write(encoded)
                    f:close()
                    saved = true
                end
            end
        end
    end

    -- 方式3: gg.saveVariable（GG内置持久化，不依赖文件系统）
    if type(gg.saveVariable) == "function" then
        pcall(gg.saveVariable, _SAVE_TAG, encoded)
        saved = true
    end

    if not saved then
        gg.toast("⚠️ 激活码保存失败，下次需重新输入")
    end
end

local function _loadActivation()
    local encoded = nil

    -- 方式1: 固定路径
    local f = io.open(_SAVE_PATH, "r")
    if f then
        encoded = f:read("*a")
        f:close()
        if encoded and encoded ~= "" then
            local key = _decodeActivation(encoded)
            if key then return key end
        end
        encoded = nil
    end

    -- 方式2: 脚本同目录
    local ok, scriptPath = pcall(gg.getFile)
    if ok and scriptPath then
        local dir = scriptPath:match("(.*/)")
        if dir then
            f = io.open(dir .. ".unity_key", "r")
            if f then
                encoded = f:read("*a")
                f:close()
                if encoded and encoded ~= "" then
                    local key = _decodeActivation(encoded)
                    if key then return key end
                end
                encoded = nil
            end
        end
    end

    -- 方式3: gg.loadVariable
    if type(gg.loadVariable) == "function" then
        local ok2, val = pcall(gg.loadVariable, _SAVE_TAG)
        if ok2 and val and type(val) == "string" and val ~= "" then
            local key = _decodeActivation(val)
            if key then return key end
        end
    end

    return nil
end

-- ============ GG保存列表（安全封装）============

local _ggListOk = false

local function _checkGGListAPI()
    if type(gg.getSavedList) == "function" and type(gg.setSavedList) == "function" and type(gg.addSavedItems) == "function" then
        _ggListOk = true
    end
end

local function _getSavedList()
    if not _ggListOk then return {} end
    local ok, list = pcall(gg.getSavedList)
    if ok and type(list) == "table" then return list end
    return {}
end

local function _addSavedItems(items)
    if not _ggListOk then return false end
    local ok, r = pcall(gg.addSavedItems, items)
    return ok
end

local function _setSavedList(list)
    if not _ggListOk then return false end
    local ok, r = pcall(gg.setSavedList, list)
    return ok
end

-- ============ 激活界面 ============

function showActivation()
    local savedKey = _loadActivation()
    if savedKey and _verifyKey(savedKey) then
        _0t = _xc("UNLOCK", _0k)
        _0v = true
        gg.toast("✅ 已激活")
        return true
    end

    local deviceCode = _getDeviceCode()

    while true do
        local input = gg.prompt(
            {"🔑 请输入激活码 (格式: XXXX-XXXX-XXXX-XXXX)"},
            {""},
            {"text"}
        )

        if not input or not input[1] or input[1] == "" then
            local c = gg.choice(
                {"🔑  重新输入激活码", "📋  复制设备码", "❌  退出脚本"},
                nil,
                "Unity加速器 v5.2.4 | xy435116694754\n━━━━━━━━━━━━━━━━━━━━━\n\n⚠️ 未输入激活码\n\n" ..
                "📋 你的设备码:\n" ..
                "━━━━━━━━━━━━━━\n" ..
                deviceCode .. "\n" ..
                "━━━━━━━━━━━━━━\n\n" ..
                "将设备码发送给作者获取激活码\n" ..
                "闲鱼: xy435116694754"
            )
            if c == 2 then
                gg.copyText(deviceCode)
                gg.toast("📋 设备码已复制: " .. deviceCode)
            elseif c ~= 1 then
                return false
            end
        else
            local key = input[1]:upper():gsub("[%s%-]", "")
            if _verifyKey(key) then
                _0t = _xc("UNLOCK", _0k)
                _0v = true
                _saveActivation(key)
                gg.alert(
                    "━━━━━━━━━━━━━━━━━━━━━\n" ..
                    "  Unity加速器 v5.2.4 | xy435116694754\n" ..
                    "━━━━━━━━━━━━━━━━━━━━━\n" ..
                    "  ✅ 激活成功！\n" ..
                    "━━━━━━━━━━━━━━━━━━━━━\n\n" ..
                    "  激活码已绑定当前设备\n" ..
                    "  删除重装无需重新激活\n\n" ..
                    "  闲鱼: " .. _gs("author") .. "\n" ..
                    "━━━━━━━━━━━━━━━━━━━━━"
                )
                return true
            else
                local c = gg.choice(
                    {"🔑  重新输入", "📋  复制设备码", "❌  退出"},
                    nil,
                    "Unity加速器 v5.2.4 | xy435116694754\n━━━━━━━━━━━━━━━━━━━━━\n\n❌ 激活码无效\n\n" ..
                    "📋 你的设备码:\n" ..
                    "━━━━━━━━━━━━━━\n" ..
                    deviceCode .. "\n" ..
                    "━━━━━━━━━━━━━━\n\n" ..
                    "请确认激活码与设备码匹配\n" ..
                    "闲鱼: xy435116694754"
                )
                if c == 2 then
                    gg.copyText(deviceCode)
                    gg.toast("📋 设备码已复制: " .. deviceCode)
                elseif c ~= 1 then
                    return false
                end
            end
        end
    end
end

-- ============ 主程序变量 ============

local speedAddr = nil
local currentSpeed = 1.0
local candidates = {}
local isUnityGame = nil       -- nil=未检测, true=Unity, false=非Unity
local unityDetectMsg = ""     -- 检测结果消息
local searchResult = ""       -- 搜索结果消息
local SAVE_TAG = "⚡TimeScale"
local APP_VER = "v5.2.4"

local CLASSIC_COMBOS = {
    {0.1, 0.03}, {0.1, 0.04}, {0.333, 0.1}, {0.333, 0.06},
    {0.333, 0.15}, {0.333, 0.03}, {0.02, 0.1}, {0.02, 0.333},
    {0.033, 0.333}, {0.03, 0.1}, {0.05, 0.1}, {0.05, 0.333},
    {0.0167, 0.1}, {0.0167, 0.333},
}

-- ============ Unity引擎检测 ============

function detectUnity()
    local pkg = gg.getSelectedPackage()
    if not pkg then return false, "未选中进程" end

    local coreFeatures = {
        {name = "libunity.so", sig = "h 6C 69 62 75 6E 69 74 79 2E 73 6F"},
        {name = "UnityEngine.Time", sig = "h 55 6E 69 74 79 45 6E 67 69 6E 65 2E 54 69 6D 65"},
    }

    local auxFeatures = {
        {name = "Time.timeScale", sig = "h 54 69 6D 65 2E 74 69 6D 65 53 63 61 6C 65"},
        {name = "Time.fixedDeltaTime", sig = "h 54 69 6D 65 2E 66 69 78 65 64 44 65 6C 74 61 54 69 6D 65"},
        {name = "Time.maximumDeltaTime", sig = "h 54 69 6D 65 2E 6D 61 78 69 6D 75 6D 44 65 6C 74 61 54 69 6D 65"},
        {name = "UnityEngine", sig = "h 55 6E 69 74 79 45 6E 67 69 6E 65"},
    }

    local il2cpp = {name = "libil2cpp.so", sig = "h 6C 69 62 69 6C 32 63 70 70 2E 73 6F"}

    for _, feat in ipairs(coreFeatures) do
        gg.clearResults()
        gg.searchNumber(feat.sig, gg.TYPE_BYTE)
        local found = gg.getResultsCount()
        gg.clearResults()
        if found > 0 then
            return true, "✅ 核心特征命中: " .. feat.name
        end
    end

    local auxHits = {}
    for _, feat in ipairs(auxFeatures) do
        gg.clearResults()
        gg.searchNumber(feat.sig, gg.TYPE_BYTE)
        local found = gg.getResultsCount()
        gg.clearResults()
        if found > 0 then
            auxHits[#auxHits + 1] = feat.name
        end
    end

    if #auxHits >= 2 then
        return true, "✅ 辅助特征命中×" .. #auxHits .. ": " .. table.concat(auxHits, ", ")
    end

    gg.clearResults()
    gg.searchNumber(il2cpp.sig, gg.TYPE_BYTE)
    local il2cppFound = gg.getResultsCount()
    gg.clearResults()
    if il2cppFound > 0 and #auxHits >= 1 then
        return true, "✅ IL2CPP + 辅助特征命中"
    end

    return false, "❌ 未检测到Unity引擎特征"
end

function runUnityDetect()
    gg.toast("🔍 正在检测Unity引擎...")
    local isUnity, msg = detectUnity()
    isUnityGame = isUnity
    unityDetectMsg = msg
    if isUnity then
        gg.alert(
            "━━━━━━━━━━━━━━━━━━━━━\n" ..
            "  🔍 Unity引擎检测\n" ..
            "━━━━━━━━━━━━━━━━━━━━━\n\n" ..
            msg .. "\n\n" ..
            "  可以使用加速功能 ✅"
        )
    else
        gg.alert(
            "━━━━━━━━━━━━━━━━━━━━━\n" ..
            "  🔍 Unity引擎检测\n" ..
            "━━━━━━━━━━━━━━━━━━━━━\n\n" ..
            msg .. "\n\n" ..
            "  ⚠️ 本脚本仅适用于Unity游戏\n" ..
            "  加速功能可能无效"
        )
    end
end

-- ============ 搜索功能 ============

function scoreResult(addr, val, nextVals)
    local score = 0
    if val > 0.5 and val < 2.0 then score = score + 10 end

    for _, combo in ipairs(CLASSIC_COMBOS) do
        if nextVals and #nextVals >= 2 then
            local diff1 = math.abs(nextVals[1] - combo[1])
            local diff2 = math.abs(nextVals[2] - combo[2])
            if diff1 < 0.01 and diff2 < 0.01 then
                score = score + 50
                break
            elseif diff1 < 0.01 then
                score = score + 5
            end
        end
    end

    if val == 1.0 then score = score + 5 end
    return score
end

function searchTimeScale()
    local pkg = gg.getSelectedPackage()
    if not pkg then
        gg.toast("❌ 请先选择游戏进程")
        return
    end

    gg.toast("🔍 搜索中...")

    gg.clearResults()
    gg.searchNumber(_gs("search_val"), gg.TYPE_FLOAT)
    local count = gg.getResultsCount()

    if count == 0 then
        searchResult = "❌ 未找到1.0F"
        gg.alert("❌ 未找到 " .. _gs("search_val") .. " 浮点数\n\n请确认游戏已加载")
        return
    end

    candidates = {}
    local batchSize = 8000
    local processed = 0

    while processed < count do
        local remaining = count - processed
        local size = math.min(batchSize, remaining)
        local results = gg.getResults(size, processed)

        for i, r in ipairs(results) do
            local nextVals = {}
            local nextAddrs = {}
            for j = 1, 4 do
                nextAddrs[j] = {
                    address = r.address + j * 4,
                    flags = gg.TYPE_FLOAT,
                    value = 0
                }
            end

            local ok, nextRes = pcall(function()
                return gg.getValues(nextAddrs)
            end)

            if ok and nextRes then
                for j, nr in ipairs(nextRes) do
                    nextVals[j] = nr.value
                end
            end

            local score = scoreResult(r.address, r.value, nextVals)

            if score > 0 then
                candidates[#candidates + 1] = {
                    address = r.address,
                    value = r.value,
                    score = score,
                    nextVals = nextVals
                }
            end
        end

        processed = processed + size
    end

    gg.clearResults()

    if #candidates == 0 then
        searchResult = "❌ " .. count .. "个1.0F, 无匹配"
        gg.alert("❌ 未找到合适的候选地址\n\n搜到 " .. count .. " 个1.0F，但无经典组合匹配")
        return
    end

    table.sort(candidates, function(a, b) return a.score > b.score end)

    if #candidates > 50 then
        candidates = {table.unpack(candidates, 1, 50)}
    end

    searchResult = "🔍 " .. #candidates .. "个候选"
    gg.alert(
        "✅ 找到 " .. #candidates .. " 个候选地址\n\n" ..
        "最高分: " .. candidates[1].score .. "\n" ..
        "地址: " .. string.format("0x%X", candidates[1].address) .. "\n\n" ..
        "开始二分法确认..."
    )

    binarySearch()
end

function binarySearch()
    if #candidates == 0 then
        gg.toast("❌ 无候选地址")
        return
    end

    local working = candidates
    local round = 0

    while #working > 1 do
        round = round + 1
        local half = math.floor(#working / 2)

        local modifyList = {}
        for i = 1, half do
            modifyList[#modifyList + 1] = {
                address = working[i].address,
                flags = gg.TYPE_FLOAT,
                value = 2.0
            }
        end

        gg.setValues(modifyList)

        local c = gg.choice(
            {"⚡  加速了 ✅", "🐌  没变化 ❌", "⏭️  跳过5个", "❌  放弃搜索"},
            nil,
            "🔄 二分法 第" .. round .. "轮 (剩余" .. #working .. "个)\n\n" ..
            "游戏速度是否变化了？"
        )

        for i = 1, half do
            modifyList[i].value = working[i].value
        end
        gg.setValues(modifyList)

        if c == 1 then
            working = {table.unpack(working, 1, half)}
        elseif c == 2 then
            working = {table.unpack(working, half + 1)}
        elseif c == 3 then
            local skip = math.min(5, #working - 1)
            working = {table.unpack(working, skip + 1)}
        else
            searchResult = "⚠️ 搜索已放弃"
            return
        end
    end

    if #working == 1 then
        speedAddr = working[1].address
        currentSpeed = 1.0
        searchResult = "✅ " .. currentSpeed .. "x " .. string.format("0x%X", speedAddr)
        saveToGGList(working[1])
        gg.alert(
            "━━━━━━━━━━━━━━━━━━━━━\n" ..
            "  ✅ 找到 " .. _gs("time_scale") .. " 地址！\n" ..
            "━━━━━━━━━━━━━━━━━━━━━\n\n" ..
            "  地址: " .. string.format("0x%X", speedAddr) .. "\n" ..
            "  当前值: " .. working[1].value .. "\n\n" ..
            "  已保存到GG列表 📋"
        )
    else
        searchResult = "❌ 未找到目标"
        gg.toast("❌ 未找到目标地址")
    end
end

-- ============ GG保存列表功能 ============

function saveToGGList(item)
    if not _ggListOk then
        gg.toast("⚠️ GG列表不可用，地址: " .. string.format("0x%X", item.address))
        return
    end
    local pkg = gg.getSelectedPackage() or ""
    local note = pkg .. "|" .. string.format("0x%X", item.address) .. "|" .. _gs("author")
    local entry = {
        address = item.address,
        flags = gg.TYPE_FLOAT,
        value = item.value,
        name = SAVE_TAG,
        tag = note
    }
    _addSavedItems({entry})
end

function loadFromGGList()
    if not _ggListOk then return false end
    local saved = _getSavedList()
    for i, item in ipairs(saved) do
        if item.name == SAVE_TAG then
            speedAddr = item.address
            currentSpeed = item.value or 1.0
            searchResult = "✅ " .. currentSpeed .. "x " .. string.format("0x%X", speedAddr) .. " (列表)"
            return true
        end
    end
    return false
end

function syncGGListValue()
    if not speedAddr or not _ggListOk then return end
    local saved = _getSavedList()
    for i, item in ipairs(saved) do
        if item.name == SAVE_TAG and item.address == speedAddr then
            saved[i].value = currentSpeed
            _setSavedList(saved)
            return
        end
    end
end

-- ============ 加速功能 ============

function setSpeed(multiplier)
    if not speedAddr then
        gg.toast("❌ 请先搜索地址")
        return
    end
    gg.setValues({
        {address = speedAddr, flags = gg.TYPE_FLOAT, value = multiplier}
    })
    currentSpeed = multiplier
    searchResult = "✅ " .. currentSpeed .. "x " .. string.format("0x%X", speedAddr)
    syncGGListValue()
    gg.toast("⚡ 加速 " .. multiplier .. "x")
end

function resetSpeed()
    if not speedAddr then return end
    gg.setValues({
        {address = speedAddr, flags = gg.TYPE_FLOAT, value = 1.0}
    })
    currentSpeed = 1.0
    searchResult = "✅ " .. currentSpeed .. "x " .. string.format("0x%X", speedAddr)
    syncGGListValue()
    gg.toast("🔄 已恢复正常速度")
end

function showSpeedMenu()
    if not speedAddr then
        gg.toast("❌ 请先搜索地址")
        return
    end

    local c = gg.choice(
        {"⚡  2x 加速", "⚡  3x 加速", "⚡  5x 加速", "⚡  10x 加速",
         "⚡  自定义倍速", "🔄  恢复正常", "🔙  返回主菜单"},
        nil,
        "⚡ " .. _gs("time_scale") .. " 加速\n\n当前: " .. currentSpeed .. "x\n地址: " .. (speedAddr and string.format("0x%X", speedAddr) or "无")
    )

    if c == 1 then setSpeed(2.0)
    elseif c == 2 then setSpeed(3.0)
    elseif c == 3 then setSpeed(5.0)
    elseif c == 4 then setSpeed(10.0)
    elseif c == 5 then
        local input = gg.prompt(
            {"🎯 输入加速倍数 (0.1 ~ 100)"},
            {"2.0"},
            {"text"}
        )
        if input and input[1] then
            local spd = tonumber(input[1])
            if spd and spd > 0 and spd <= 100 then
                setSpeed(spd)
            else
                gg.toast("❌ 无效倍数")
            end
        end
    elseif c == 6 then resetSpeed()
    end
end

-- ============ 主菜单 ============

function showMenu()
    -- 搜索状态
    local status = searchResult
    if status == "" then
        status = speedAddr and ("✅ " .. currentSpeed .. "x") or "❌ 未搜索"
    end

    -- Unity检测状态
    local unityStatus = "❓ 未检测"
    if isUnityGame == true then
        unityStatus = "✅ Unity游戏"
    elseif isUnityGame == false then
        unityStatus = "❌ 非Unity"
    end

    local c = gg.choice(
        {"🔍  搜索 " .. _gs("time_scale"), "⚡  加速设置",
         "🔎  Unity引擎检测", "ℹ️  关于", "❌  退出"},
        nil,
        _gs("app_name") .. " " .. APP_VER .. "\n━━━━━━━━━━━━━━━━━━━━━\n" ..
        "搜索: " .. status .. "\n" ..
        "引擎: " .. unityStatus .. "\n" ..
        "━━━━━━━━━━━━━━━━━━━━━"
    )

    if c == 1 then searchTimeScale()
    elseif c == 2 then showSpeedMenu()
    elseif c == 3 then runUnityDetect()
    elseif c == 4 then showAbout()
    end
end

function showAbout()
    gg.alert(
        "━━━━━━━━━━━━━━━━━━━━━\n" ..
        "  " .. _gs("about_info") .. "\n" ..
        "━━━━━━━━━━━━━━━━━━━━━\n\n" ..
        "  功能: Unity " .. _gs("time_scale") .. " 加速\n" ..
        "  引擎: 自动检测Unity\n" ..
        "  激活: 设备绑定 (一机一码)\n" ..
        "  更新: 云端自动更新\n\n" ..
        "  闲鱼: " .. _gs("author") .. "\n" ..
        "━━━━━━━━━━━━━━━━━━━━━"
    )
end

-- ============ 启动 ============

_checkGGListAPI()

if not showActivation() then
    gg.toast("❌ 未激活，脚本退出")
    return
end

gg.alert(
    "━━━━━━━━━━━━━━━━━━━━━\n" ..
    "  " .. _gs("unity_tag") .. "\n" ..
    "━━━━━━━━━━━━━━━━━━━━━\n\n" ..
    "  Unity游戏专用加速器\n" ..
    "  自动搜索 | 二分确认 | 云端更新\n\n" ..
    "  闲鱼: " .. _gs("author") .. "\n" ..
    "━━━━━━━━━━━━━━━━━━━━━"
)

loadFromGGList()

while true do
    if gg.isVisible(true) then
        gg.setVisible(false)
        showMenu()
    end
    gg.sleep(100)
end
