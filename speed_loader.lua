-- ============================================================
--  Unity加速器 在线加载器 v5.2
--  多CDN源加载，国内无需VPN
--  署名: xy435116694754
-- ============================================================

local CDN_URLS = {
    "https://cdn.jsdelivr.net/gh/asz184786914-eng/lua-scripts@main/speed_hack.lua",
    "https://fastly.jsdelivr.net/gh/asz184786914-eng/lua-scripts@main/speed_hack.lua",
    "https://testingcf.jsdelivr.net/gh/asz184786914-eng/lua-scripts@main/speed_hack.lua",
    "https://raw.githubusercontent.com/asz184786914-eng/lua-scripts/main/speed_hack.lua",
}
local LOCAL_FILE = "speed_hack.lua"

gg.toast("🌐 正在加载脚本...")

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
    local dir = gg.getFile():match("(.*[/\\])") or "/sdcard/"
    local path = dir .. LOCAL_FILE
    local f = io.open(path, "r")
    if not f then return nil end
    local code = f:read("*a")
    f:close()
    if type(code) == "string" and #code > 100 then return code end
    return nil
end

-- 依次尝试各CDN源
local scriptCode = nil
for i, url in ipairs(CDN_URLS) do
    scriptCode = tryLoad(url)
    if scriptCode then
        gg.toast("✅ 加载成功 (源" .. i .. ")")
        break
    end
end

-- 全部CDN失败，尝试本地
if not scriptCode then
    gg.toast("⚠️ 云端加载失败，尝试本地...")
    scriptCode = loadFromLocal()
    if scriptCode then
        gg.toast("✅ 本地加载成功")
    else
        gg.alert("❌ 加载失败！\n\n请检查网络连接或确保本地有 speed_hack.lua 文件")
        return
    end
end

local fn, err = load(scriptCode)
if fn then
    fn()
else
    gg.alert("❌ 脚本解析错误:\n" .. tostring(err))
end
