-- ============================================================
-- ╔══════════════════════════════════════════════╗
-- ║   Unity Time.timeScale 加速器 v5.2.7          ║
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
    if raw == "" then
        -- 硬件信息都拿不到时，用 android.id 替代
        local ok, aid = pcall(gg.makeRequest, "content://settings/secure/android_id")
        raw = (ok and type(aid) == "string" and aid ~= "") and aid or "default_device"
    end
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
    local data = fp .. "#" .. actKey
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
    local savedFP = decoded:match("^(.+)#")
    local savedKey = decoded:match("#(.+)$")
    if not savedFP or not savedKey then return nil end
    local currentFP = _getDeviceFP()
    if savedFP ~= currentFP then return nil end
    return savedKey
end

local function _writeFile(path, data)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(data)
    f:close()
    -- 验证写入
    local vf = io.open(path, "r")
    if not vf then return false end
    local v = vf:read("*a")
    vf:close()
    return v == data
end

local function _saveActivation(actKey)
    local encoded = _encodeActivation(actKey)
    local saved = false
    local methods = {}

    -- 方式1: 固定路径 /sdcard/.unity_key
    if _writeFile(_SAVE_PATH, encoded) then
        saved = true
        methods[#methods + 1] = "固定路径"
    end

    -- 方式2: 脚本同目录
    local ok, scriptPath = pcall(gg.getFile)
    if ok and scriptPath then
        local dir = scriptPath:match("(.*/)")
        if dir then
            local p = dir .. ".unity_key"
            if _writeFile(p, encoded) then
                saved = true
                methods[#methods + 1] = "脚本目录"
            end
        end
    end

    -- 方式3: /data/local/tmp/ (Root设备通常可写)
    local tmpPath = "/data/local/tmp/.unity_key"
    if _writeFile(tmpPath, encoded) then
        saved = true
        methods[#methods + 1] = "tmp目录"
    end

    -- 方式4: gg.saveVariable
    if type(gg.saveVariable) == "function" then
        local ok2, err = pcall(gg.saveVariable, _SAVE_TAG, encoded)
        if ok2 then
            saved = true
            methods[#methods + 1] = "GG存储"
        end
    end

    -- 方式5: 通过su写文件 (Root)
    if not saved then
        local suCmd = "echo '" .. encoded .. "' > " .. _SAVE_PATH
        local ok3 = pcall(os.execute, "su -c '" .. suCmd .. "'")
        if ok3 then
            local vf = io.open(_SAVE_PATH, "r")
            if vf then
                local v = vf:read("*a")
                vf:close()
                if v == encoded then
                    saved = true
                    methods[#methods + 1] = "Root写入"
                end
            end
        end
    end

    if saved then
        gg.toast("✅ 激活码已保存 (" .. table.concat(methods, "+") .. ")")
    else
        gg.toast("⚠️ 激活码保存失败，下次需重新输入")
    end
end

local function _loadActivation()
    local paths = {
        _SAVE_PATH,
        "/data/local/tmp/.unity_key",
    }

    -- 脚本同目录
    local ok, scriptPath = pcall(gg.getFile)
    if ok and scriptPath then
        local dir = scriptPath:match("(.*/)")
        if dir then
            paths[#paths + 1] = dir .. ".unity_key"
        end
    end

    -- 逐路径读取
    for _, path in ipairs(paths) do
        local f = io.open(path, "r")
        if f then
            local encoded = f:read("*a")
            f:close()
            if encoded and encoded ~= "" then
                local key = _decodeActivation(encoded)
                if key then return key end
            end
        end
    end

    -- gg.loadVariable
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
    -- 检查加载器预注入的激活码
    if _PRELOADED_ACT and _PRELOADED_ACT ~= "" then
        local key = _decodeActivation(_PRELOADED_ACT)
        if key and _verifyKey(key) then
            _0t = _xc("UNLOCK", _0k)
            _0v = true
            gg.toast("✅ 已激活")
            return true
        end
    end

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
                "Unity加速器 v5.2.7 | xy435116694754\n━━━━━━━━━━━━━━━━━━━━━\n\n⚠️ 未输入激活码\n\n" ..
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
                    "  Unity加速器 v5.2.7 | xy435116694754\n" ..
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
                    "Unity加速器 v5.2.7 | xy435116694754\n━━━━━━━━━━━━━━━━━━━━━\n\n❌ 激活码无效\n\n" ..
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
local unityLevel = -1          -- -1=未检测, 0-4 可信度等级
local unityDetectMsg = ""     -- 检测结果消息
local searchResult = ""       -- 搜索结果消息
local SAVE_TAG = "⚡TimeScale"
local APP_VER = "v5.2.7"

-- ============ Unity引擎检测 ============

local isUnityGame = nil       -- nil=未检测, true=Unity, false=非Unity
local unityLevel = -1          -- -1=未检测, 0-4 可信度等级
local unityDetectMsg = ""     -- 检测结果消息

function detectUnity()
    local pkg = gg.getSelectedPackage()
    if not pkg then return false, 0, "未选中进程" end

    local coreFeatures = {
        {name = "libunity.so", sig = "h 6C 69 62 75 6E 69 74 79 2E 73 6F"},
        {name = "UnityEngine.Time", sig = "h 55 6E 69 74 79 45 6E 67 69 6E 65 2E 54 69 6D 65"},
    }

    local auxFeatures = {
        {name = "Time.timeScale", sig = "h 54 69 6D 65 2E 74 69 6D 65 53 63 61 6C 65"},
        {name = "Time.fixedDeltaTime", sig = "h 54 69 6D 65 2E 66 69 78 65 64 44 65 6C 74 61 54 69 6D 65"},
        {name = "Time.maximumDeltaTime", sig = "h 54 69 6D 65 2E 6D 61 78 69 6D 75 6D 44 65 6C 74 61 54 69 6D 65"},
        {name = "UnityEngine", sig = "h 55 6E 69 74 79 45 6E 67 69 6E 65"},
        {name = "libil2cpp.so", sig = "h 6C 69 62 69 6C 32 63 70 70 2E 73 6F"},
    }

    -- 检测核心特征
    local coreFound = {}
    local coreHitCount = 0
    for _, feat in ipairs(coreFeatures) do
        gg.clearResults()
        gg.searchNumber(feat.sig, gg.TYPE_BYTE)
        local found = gg.getResultsCount()
        gg.clearResults()
        coreFound[feat.name] = (found > 0)
        if found > 0 then coreHitCount = coreHitCount + 1 end
    end

    -- 检测辅助特征
    local auxFound = {}
    local auxHitCount = 0
    for _, feat in ipairs(auxFeatures) do
        gg.clearResults()
        gg.searchNumber(feat.sig, gg.TYPE_BYTE)
        local found = gg.getResultsCount()
        gg.clearResults()
        auxFound[feat.name] = (found > 0)
        if found > 0 then auxHitCount = auxHitCount + 1 end
    end

    local totalHits = coreHitCount + auxHitCount
    local total = #coreFeatures + #auxFeatures

    -- 可信度判定
    local level, label, isUnity
    if totalHits >= 6 then
        level = 4; label = "🟢 高可信度"; isUnity = true
    elseif totalHits >= 4 then
        level = 3; label = "🟡 中可信度"; isUnity = true
    elseif totalHits >= 2 then
        level = 2; label = "🟠 低可信度"; isUnity = nil
    elseif totalHits == 1 then
        level = 1; label = "🔴 疑似非Unity"; isUnity = false
    else
        level = 0; label = "⚫ 非Unity"; isUnity = false
    end

    -- 构建详情
    local detail = label .. " (" .. totalHits .. "/" .. total .. ")\n\n"
    detail = detail .. "核心验证 (" .. coreHitCount .. "/" .. #coreFeatures .. ")\n"
    for _, feat in ipairs(coreFeatures) do
        if coreFound[feat.name] then
            detail = detail .. "  ✅ " .. feat.name .. "\n"
        else
            detail = detail .. "  ❌ " .. feat.name .. "\n"
        end
    end

    detail = detail .. "\n辅助验证 (" .. auxHitCount .. "/" .. #auxFeatures .. ")\n"
    for _, feat in ipairs(auxFeatures) do
        if auxFound[feat.name] then
            detail = detail .. "  ✅ " .. feat.name .. "\n"
        else
            detail = detail .. "  ❌ " .. feat.name .. "\n"
        end
    end

    return isUnity, level, detail
end

function runUnityDetect()
    gg.toast("🔍 正在检测Unity引擎...")
    local isUnity, level, detail = detectUnity()
    isUnityGame = isUnity
    unityDetectMsg = detail

    local advice = ""
    if level == 4 then
        advice = "所有特征命中，请尝试使用"
    elseif level == 3 then
        advice = "大部分特征命中，可进行尝试"
    elseif level == 2 then
        advice = "🟠 命中特征较少，可能不是Unity\n加速功能可能无效，建议手动确认"
    elseif level == 1 then
        advice = "🔴 仅1个特征命中，疑似非Unity\n加速功能大概率无效"
    else
        advice = "⚫ 未检测到任何Unity特征\n加速功能无效"
    end

    gg.alert(
        "─────────────────────\n" ..
        "🔍 Unity引擎检测\n" ..
        "─────────────────────\n\n" ..
        detail .. "\n" ..
        advice
    )
end

-- ============ 搜索功能 ============

local CLASSIC_COMBOS = {
    {0.1, 0.03},
    {0.1, 0.04},
    {0.333, 0.1},
    {0.333, 0.06},
    {0.333, 0.15},
    {0.333, 0.03},
    {0.02, 0.1},
    {0.02, 0.333},
    {0.033, 0.333},
    {0.03, 0.1},
    {0.05, 0.1},
    {0.05, 0.333},
    {0.0167, 0.1},
    {0.0167, 0.333},
}

-- ============ 搜索主流程 ============

function searchTimeScale()
    local pkg = gg.getSelectedPackage()
    if not pkg then
        gg.toast("❌ 请先选择游戏进程")
        return
    end

    -- 选择是否指定地址范围
    local rangeChoice = gg.choice(
        {"🔍 全范围搜索", "📍 指定地址范围"},
        1,
        "选择搜索范围"
    )
    if not rangeChoice then return end

    local addrStart = nil
    local addrEnd = nil

    if rangeChoice == 2 then
        local rangeInput = gg.prompt(
            {"起始地址 (hex, 如 6c0c000000)", "结束地址 (hex, 如 6f2e8cffff)"},
            {"0", "FFFFFFFFFFFFFFFF"},
            {"text", "text"}
        )
        if not rangeInput then return end
        addrStart = tonumber(rangeInput[1], 16)
        addrEnd = tonumber(rangeInput[2], 16)
        if not addrStart or not addrEnd or addrStart >= addrEnd then
            gg.alert("❌ 地址范围无效\n请确保起始地址 < 结束地址")
            return
        end
    end

    candidates = {}

    gg.toast("🔍 搜索1.0f中...")
    gg.clearResults()
    gg.searchNumber("1.0", gg.TYPE_FLOAT)
    local count = gg.getResultsCount()
    if count == 0 then
        searchResult = "❌ 未找到1.0F"
        gg.alert("❌ 未找到浮点数\n\n请确认游戏已加载")
        return
    end

    -- 可选保留数量
    local keepInput = gg.prompt({"保留得分前N个候选"}, {"1000"}, {"number"})
    local KEEP = keepInput and tonumber(keepInput[1]) or 1000
    if KEEP < 10 then KEEP = 10 end

    local rangeHint = addrStart and (" (范围: 0x" .. string.format("%X", addrStart) .. "~0x" .. string.format("%X", addrEnd) .. ")") or ""
    gg.alert("✅ 搜到 " .. count .. " 个1.0f" .. rangeHint .. "\n\n即将开始评分，请稍候...")

    -- 分批处理所有结果，范围内过滤
    local BATCH = 50000
    local offset = 0
    local rangeHits = 0

    while offset < count do
        local batchCount = math.min(BATCH, count - offset)
        local results = gg.getResults(batchCount, offset)

        -- 先过滤出范围内的结果
        local filtered = {}
        for i = 1, #results do
            if not addrStart or (results[i].address >= addrStart and results[i].address <= addrEnd) then
                filtered[#filtered + 1] = results[i]
            end
        end
        rangeHits = rangeHits + #filtered

        -- 只对范围内的结果读取+4和+8
        if #filtered > 0 then
            local readList = {}
            for i = 1, #filtered do
                readList[#readList + 1] = {address = filtered[i].address + 4, flags = gg.TYPE_FLOAT}
                readList[#readList + 1] = {address = filtered[i].address + 8, flags = gg.TYPE_FLOAT}
            end
            local vals = gg.getValues(readList)

            for i = 1, #filtered do
                local val2 = vals[(i - 1) * 2 + 1].value
                local val3 = vals[(i - 1) * 2 + 2].value
                local score = calcScore(val2, val3)
                candidates[#candidates + 1] = {
                    address = filtered[i].address,
                    score = score,
                    val2 = val2,
                    val3 = val3
                }
            end
        end

        offset = offset + batchCount
        local pct = math.floor(math.min(offset, count) / count * 100)
        if addrStart then
            gg.toast("📍 范围内: " .. rangeHits .. "/" .. math.min(offset, count))
        else
            gg.toast("📊 评分进度: " .. math.min(offset, count) .. "/" .. count)
        end
    end

    gg.clearResults()

    -- 按得分排序
    table.sort(candidates, function(a, b) return a.score > b.score end)

    -- 只保留前KEEP个
    if #candidates > KEEP then
        local trimmed = {}
        for i = 1, KEEP do trimmed[i] = candidates[i] end
        candidates = trimmed
    end

    if #candidates == 0 then
        searchResult = "❌ 无候选地址"
        gg.alert("❌ 未找到合适的候选地址")
        return
    end

    -- 显示结果
    searchResult = "🔍 " .. #candidates .. "个候选"
    local info = "评分完成！\n\n" ..
        "搜到 " .. count .. " 个1.0f\n" ..
        "有 " .. #candidates .. " 个候选（保留前" .. KEEP .. "）\n" ..
        "最高分: " .. (candidates[1] and candidates[1].score or 0)
    if #candidates > 0 then
        info = info .. "\n\nTOP3:\n"
        for i = 1, math.min(3, #candidates) do
            info = info .. string.format("#%d 得分:%d +4:%.6f +8:%.6f\n",
                i, candidates[i].score, candidates[i].val2, candidates[i].val3)
        end
    end
    info = info .. "\n即将使用二分法确认"
    gg.alert(info)

    binarySearch()
end

-- ============ 评分函数 ============

function isGoodFloat(v)
    if v == nil then return false end
    if v ~= v then return false end
    if v == math.huge or v == -math.huge then return false end
    if v < -10000 or v > 10000 then return false end
    return true
end

function near(v, target)
    return math.abs(v - target) < 0.001
end

function calcScore(val2, val3)
    local score = 0

    if isGoodFloat(val2) then
        score = score + 50
        if near(val2, 0.333333) then score = score + 40 end
        if near(val2, 0.033333) then score = score + 40 end
        if near(val2, 0.02) then score = score + 35 end
        if near(val2, 0.016666) or near(val2, 0.0167) then score = score + 35 end
        if near(val2, 0.011111) then score = score + 30 end
        if near(val2, 0.1) then score = score + 30 end
        if near(val2, 0.05) then score = score + 20 end
        if near(val2, 0.03) then score = score + 35 end
        if val2 > 0 and val2 < 0.5 then score = score + 15 end
        if val2 > 0.5 and val2 < 1.0 then score = score + 5 end
        if val2 >= 5.0 then score = score - 30 end
        if val2 >= 10.0 then score = score - 40 end
    else
        score = -100
    end

    if isGoodFloat(val3) then
        score = score + 20
        if near(val3, 0.1) then score = score + 30 end
        if near(val3, 0.333333) then score = score + 25 end
        if near(val3, 0.05) then score = score + 20 end
        if near(val3, 0.033333) then score = score + 15 end
        if near(val3, 0.03) then score = score + 25 end
        if near(val3, 0.02) then score = score + 20 end
        if val3 > 0 and val3 < 0.5 then score = score + 10 end
        if val3 >= 5.0 then score = score - 20 end
    else
        score = score - 30
    end

    -- 经典组合加分
    if isGoodFloat(val2) and isGoodFloat(val3) then
        for _, c in ipairs(CLASSIC_COMBOS) do
            if near(val2, c[1]) and near(val3, c[2]) then
                score = score + 50
                break
            end
        end
    end

    return score
end

-- ============ 二分法 ============

function binarySearch()
    if #candidates == 0 then
        gg.alert("没有候选地址")
        return
    end

    local lo = 1
    local hi = #candidates

    while lo < hi do
        local mid = math.floor((lo + hi) / 2)

        local modifyList = {}
        for i = lo, mid do
            modifyList[#modifyList + 1] = {address = candidates[i].address, flags = gg.TYPE_FLOAT, value = 5.0}
        end
        gg.setValues(modifyList)

        local choice = gg.choice(
            {"✅ 速度变了！在这组里", "❌ 没变化，在另一组"},
            nil,
            "二分法测试\n" ..
            "测试: #" .. lo .. " ~ #" .. mid .. " (共" .. (mid - lo + 1) .. "个)\n" ..
            "另一半: #" .. (mid + 1) .. " ~ #" .. hi .. "\n" ..
            "已将前半组改为5.0x，速度变了吗？"
        )

        local restoreList = {}
        for i = lo, mid do
            restoreList[#restoreList + 1] = {address = candidates[i].address, flags = gg.TYPE_FLOAT, value = 1.0}
        end
        gg.setValues(restoreList)

        if choice == 1 then
            hi = mid
        elseif choice == 2 then
            lo = mid + 1
        else
            searchResult = "⚠️ 搜索已放弃"
            return
        end

        if hi - lo < 5 then
            testOneByOne(lo, hi)
            return
        end
    end

    testSingle(lo)
end

-- ============ 逐个测试 ============

function testOneByOne(lo, hi)
    for i = lo, hi do
        gg.setValues({{address = candidates[i].address, flags = gg.TYPE_FLOAT, value = 5.0}})
        local c = gg.choice(
            {"✅ 就是它！", "❌ 不是，下一个", "🔙 退出测试"},
            nil,
            "逐个测试 " .. (i - lo + 1) .. "/" .. (hi - lo + 1) ..
            " (得分:" .. candidates[i].score .. ")" ..
            "\n地址: " .. string.format("0x%X", candidates[i].address) ..
            string.format(" +4:%.6f +8:%.6f", candidates[i].val2, candidates[i].val3) ..
            "\n已改为5.0x，速度变了吗？"
        )
        if c == 1 then
            speedAddr = candidates[i].address
            currentSpeed = 1.0
            searchResult = "✅ " .. currentSpeed .. "x " .. string.format("0x%X", speedAddr)
            saveToGGList(candidates[i])
            gg.alert(
                "✅ 找到 timeScale 地址！\n\n" ..
                "地址: " .. string.format("0x%X", speedAddr) .. "\n" ..
                "当前值: 1.0\n\n" ..
                "已保存到GG列表"
            )
            return
        elseif c == 3 then
            gg.setValues({{address = candidates[i].address, flags = gg.TYPE_FLOAT, value = 1.0}})
            return
        end
        gg.setValues({{address = candidates[i].address, flags = gg.TYPE_FLOAT, value = 1.0}})
    end
    gg.alert("范围内未找到 timeScale\n\n可重新搜索或检查区域设置")
end

function testSingle(idx)
    gg.setValues({{address = candidates[idx].address, flags = gg.TYPE_FLOAT, value = 5.0}})
    local c = gg.choice(
        {"✅ 就是它！", "❌ 不是"},
        nil,
        "最后1个候选\n地址: " .. string.format("0x%X", candidates[idx].address) ..
        " 得分:" .. candidates[idx].score ..
        "\n已改为5.0x，速度变了吗？"
    )
    if c == 1 then
        speedAddr = candidates[idx].address
        currentSpeed = 1.0
        searchResult = "✅ " .. currentSpeed .. "x " .. string.format("0x%X", speedAddr)
        saveToGGList(candidates[idx])
        gg.alert(
            "✅ 找到 timeScale 地址！\n\n" ..
            "地址: " .. string.format("0x%X", speedAddr) .. "\n" ..
            "当前值: 1.0\n\n" ..
            "已保存到GG列表"
        )
    else
        gg.setValues({{address = candidates[idx].address, flags = gg.TYPE_FLOAT, value = 1.0}})
        gg.alert("未找到 timeScale")
    end
end

function saveToGGList(item)
    local pkg = gg.getSelectedPackage() or ""
    local note = "TimeScale | " .. pkg .. " | " .. string.format("0x%X", item.address)
    -- 先清除旧的保存项
    local ok, items = pcall(gg.getListItems)
    if ok and items then
        local toRemove = {}
        for i = 1, #items do
            if items[i].name and string.find(items[i].name, "TimeScale") then
                toRemove[#toRemove + 1] = i
            end
        end
        if #toRemove > 0 then
            pcall(gg.removeListItems, toRemove)
        end
    end
    -- 添加到GG地址列表
    pcall(gg.addListItems, {{
        address = item.address,
        flags = gg.TYPE_FLOAT,
        name = note,
        value = 1.0
    }})
    gg.toast("📋 已保存到GG地址列表")
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

function readCurrentSpeed()
    if not speedAddr then return 1.0 end
    local ok, vals = pcall(gg.getValues, {{address = speedAddr, flags = gg.TYPE_FLOAT}})
    if ok and vals and vals[1] then
        return vals[1].value
    end
    return currentSpeed
end

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
        "⚡ " .. _gs("time_scale") .. " 加速\n\n当前: " .. readCurrentSpeed() .. "x\n地址: " .. (speedAddr and string.format("0x%X", speedAddr) or "无")
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
        status = speedAddr and ("✅ " .. readCurrentSpeed() .. "x") or "❌ 未搜索"
    end

    -- Unity检测状态
    local unityStatus = "❓ 未检测"
    local levelLabels = {[0]="", [1]="🔴疑似非Unity", [2]="🟠低可信度", [3]="🟡中可信度", [4]="🟢高可信度"}
    if isUnityGame == true then
        local lv = levelLabels[unityLevel] or ""
        unityStatus = "🟢 Unity" .. (lv ~= "" and "(" .. lv .. ")" or "")
    elseif isUnityGame == nil and unityDetectMsg ~= "" then
        local lv = levelLabels[unityLevel] or ""
        unityStatus = "🟠 待确认" .. (lv ~= "" and "(" .. lv .. ")" or "")
    elseif isUnityGame == false then
        local lv = levelLabels[unityLevel] or ""
        unityStatus = "❌ 非Unity" .. (lv ~= "" and "(" .. lv .. ")" or "")
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
    "🚀 Unity加速器 " .. APP_VER .. "\n" ..
    "┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄\n" ..
    "📦 引擎 v5.1 | 📡 加载器 " .. (LOADER_VER or "独立模式") .. "\n" ..
    "┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄\n\n" ..
    "🎮 Unity Time控制\n\n" ..
    "🔍 智能内存搜索 (50K/轮)\n\n" ..
    "⚖️ 交互式二分确认\n\n" ..
    "☁️ 多CDN云端更新\n\n" ..
    "─────────────────────\n" ..
    "🐟 " .. _gs("author")
)

loadFromGGList()

while true do
    if gg.isVisible(true) then
        gg.setVisible(false)
        showMenu()
    end
    gg.sleep(100)
end
