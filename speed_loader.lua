-- ============================================================
--  Unity加速器 在线加载器 v5.1
--  优先从GitHub云端加载主脚本，失败则使用本地文件
--  署名: xy435116694754
-- ============================================================

local CLOUD_URL = "https://raw.githubusercontent.com/asz184786914-eng/lua-scripts/main/speed_hack.lua"
local LOCAL_FILE = "speed_hack.lua"

gg.toast("🌐 正在加载脚本...")

local function loadFromCloud()
    local ok, code = pcall(function()
        return gg.makeRequest(CLOUD_URL)
    end)
    if ok and code and type(code) == "string" and #code > 100 then
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
    if code and #code > 100 then return code end
    return nil
end

-- 优先云端
local scriptCode = loadFromCloud()

if scriptCode then
    gg.toast("✅ 云端加载成功")
else
    gg.toast("⚠️ 云端加载失败，尝试本地...")
    scriptCode = loadFromLocal()
    if scriptCode then
        gg.toast("✅ 本地加载成功")
    else
        gg.alert("❌ 加载失败！\n\n请检查网络连接或确保本地有 speed_hack.lua 文件")
        return
    end
end

-- 执行主脚本
local fn, err = load(scriptCode)
if fn then
    fn()
else
    gg.alert("❌ 脚本解析错误:\n" .. tostring(err))
end
