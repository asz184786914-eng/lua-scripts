-- ============================================================
-- ╔══════════════════════════════════════════════╗
-- ║   Unity加速器 - 在线加载器                    ║
-- ║   优先GitHub云端，失败用本地                   ║
-- ║   署名: xy435116694754                      ║
-- ╚══════════════════════════════════════════════╝
-- ============================================================

local APP_NAME = "Unity加速器"

-- ====== 远程脚本地址 ======
local SCRIPT_URLS = {
    "https://raw.githubusercontent.com/asz184786914-eng/lua-scripts/main/speed_hack.lua",
}

-- ====== 尝试云端加载 ======
function tryCloudLoad()
    for i, url in ipairs(SCRIPT_URLS) do
        gg.toast("☁️ 加载云端源 " .. i .. "/" .. #SCRIPT_URLS)
        local ok, response = pcall(function()
            return gg.makeRequest(url)
        end)
        if ok and response and response ~= "" then
            if string.find(response, "timeScale") then
                local func, err = loadstring(response)
                if func then
                    local ver = string.match(response, 'APP_VER%s*=%s*"([^"]+)"') or "?"
                    gg.toast("✅ 云端 " .. ver .. " 加载成功！")
                    return func
                end
            end
        end
    end
    return nil
end

-- ====== 本地加载 ======
function runLocal()
    local localPath = gg.getFile():match("(.*[/\\])") .. "speed_hack.lua"
    local f = io.open(localPath, "r")
    if f then
        local content = f:read("*a")
        f:close()
        local func = loadstring(content)
        if func then
            gg.toast("📁 本地版加载成功")
            func()
            return true
        end
    end
    return false
end

-- ====== 主逻辑 ======
gg.toast("⚡ " .. APP_NAME .. " 启动中...")

local cloudFunc = tryCloudLoad()
if cloudFunc then
    cloudFunc()
else
    gg.toast("☁️ 云端不可用，切换本地...")
    if not runLocal() then
        local c = gg.choice(
            {"🔄  重试云端", "❌  退出"},
            nil,
            "⚠️ 加载失败\n\n云端不可用\n本地未找到 speed_hack.lua\n\n请检查网络或将主脚本放同目录"
        )
        if c == 1 then
            local retry = tryCloudLoad()
            if retry then retry() else gg.alert("❌ 重试失败") end
        end
    end
end
