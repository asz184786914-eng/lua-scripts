-- ============================================================
--  Unity加速器 在线加载器 v4.7
--  多CDN源 + 重试 + 本地回退
--  署名: xy435116694754
-- ============================================================

local CDN_URLS = {
    {name = "jsDelivr国内", url = "https://cdn.jsdelivr.net/gh/asz184786914-eng/lua-scripts@fa4dcf4/speed_hack.lua"},
    {name = "Fastly节点",   url = "https://fastly.jsdelivr.net/gh/asz184786914-eng/lua-scripts@fa4dcf4/speed_hack.lua"},
    {name = "CF国内镜像",   url = "https://testingcf.jsdelivr.net/gh/asz184786914-eng/lua-scripts@fa4dcf4/speed_hack.lua"},
    {name = "gcore节点",    url = "https://gcore.jsdelivr.net/gh/asz184786914-eng/lua-scripts@fa4dcf4/speed_hack.lua"},
    {name = "GitHub原始",   url = "https://raw.githubusercontent.com/asz184786914-eng/lua-scripts/main/speed_hack.lua"},
}
local LOCAL_FILE = "speed_hack.lua"
local MAX_RETRY = 2

gg.toast("🌐 正在加载脚本...")

-- ============ 预读取本地激活码 ============
local _savedActData = nil
local _actPaths = {
    "/sdcard/.unity_key",
    "/data/local/tmp/.unity_key",
}

-- 尝试从文件读取
for _, p in ipairs(_actPaths) do
    local f = io.open(p, "r")
    if f then
        local d = f:read("*a")
        f:close()
        if d and d ~= "" then
            _savedActData = d
            break
        end
    end
end

-- 脚本同目录
if not _savedActData then
    local ok, sp = pcall(gg.getFile)
    if ok and sp then
        local dir = sp:match(".*/")
        if dir then
            local f = io.open(dir .. ".unity_key", "r")
            if f then
                local d = f:read("*a")
                f:close()
                if d and d ~= "" then _savedActData = d end
            end
        end
    end
end

-- gg.loadVariable
if not _savedActData then
    if type(gg.loadVariable) == "function" then
        local ok2, val = pcall(gg.loadVariable, "unity_act")
        if ok2 and val and type(val) == "string" and val ~= "" then
            _savedActData = val
        end
    end
end

if _savedActData then
    gg.toast("📋 已读取本地激活信息")
end

local function tryLoad(url)
    local ok, resp = pcall(function()
        return gg.makeRequest(url)
    end)
    if not ok or not resp then return nil end

    local code = resp
    if type(resp) == "table" then
        code = resp.content or resp.body or resp.string or resp[1]
    end

    if type(code) == "string" and #code > 100 and string.find(code, "timeScale") then
        return code
    end
    return nil
end

local function loadFromLocal()
    local paths = {
        (gg.getFile():match("(.*[/\\])") or "/sdcard/") .. LOCAL_FILE,
        "/sdcard/" .. LOCAL_FILE,
        "/sdcard/自动精灵/" .. LOCAL_FILE,
        "/sdcard/Download/" .. LOCAL_FILE,
    }
    for _, path in ipairs(paths) do
        local f = io.open(path, "r")
        if f then
            local code = f:read("*a")
            f:close()
            if type(code) == "string" and #code > 100 and string.find(code, "timeScale") then
                return code, path
            end
        end
    end
    return nil
end

-- 依次尝试各CDN源
local scriptCode = nil
local usedSource = ""

for _, cdn in ipairs(CDN_URLS) do
    for attempt = 1, MAX_RETRY do
        gg.toast("📡 " .. cdn.name .. " (尝试" .. attempt .. "/" .. MAX_RETRY .. ")")
        scriptCode = tryLoad(cdn.url)
        if scriptCode then
            usedSource = cdn.name
            break
        end
        if attempt < MAX_RETRY then
            gg.sleep(1500)
        end
    end
    if scriptCode then break end
end

-- 全部CDN失败，尝试本地
if not scriptCode then
    gg.toast("⚠️ 网络连接失败，尝试调用本地文件...")
    local localPath
    scriptCode, localPath = loadFromLocal()
    if scriptCode then
        usedSource = "本地"
        gg.alert(
            "━━━━━━━━━━━━━━━━━━━━━\n" ..
            "  ⚠️ 网络连接失败\n" ..
            "━━━━━━━━━━━━━━━━━━━━━\n\n" ..
            "  已回退到本地文件\n\n" ..
            "  📂 文件目录:\n" ..
            "  " .. (localPath or "未知") .. "\n\n" ..
            "  ⚠️ 本地文件可能不是最新版\n" ..
            "  联网后建议删除本地文件\n" ..
            "  让加载器自动获取更新\n" ..
            "━━━━━━━━━━━━━━━━━━━━━"
        )
    else
        gg.alert(
            "━━━━━━━━━━━━━━━━━━━━━\n" ..
            "  ❌ 脚本加载失败\n" ..
            "━━━━━━━━━━━━━━━━━━━━━\n\n" ..
            "  所有云端源和本地文件均不可用\n\n" ..
            "  📱 解决方法：\n" ..
            "  1. 检查网络连接（WiFi/流量）\n" ..
            "  2. 如在国内，尝试开启VPN后重试\n" ..
            "  3. 或手动下载 speed_hack.lua\n" ..
            "     放到手机存储根目录\n\n" ..
            "  📋 下载地址（任选一个）：\n" ..
            "  · cdn.jsdelivr.net（国内直连）\n" ..
            "  · raw.githubusercontent.com（需VPN）\n\n" ..
            "  仓库: asz184786914-eng/lua-scripts\n" ..
            "━━━━━━━━━━━━━━━━━━━━━"
        )
        return
    end
else
    gg.toast("✅ v4.7 加载成功 [" .. usedSource .. "]")
end

-- 注入预读取的激活码到主脚本
if _savedActData and scriptCode then
    scriptCode = "LOADER_VER = \"v4.7\"\n" .. "_PRELOADED_ACT = [[" .. _savedActData .. "]]\n" .. scriptCode
end

local fn, err = load(scriptCode)
if fn then
    fn()
else
    gg.alert("❌ 脚本解析错误:\n" .. tostring(err))
end
