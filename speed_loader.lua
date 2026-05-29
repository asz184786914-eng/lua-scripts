-- ============================================================
-- ╔══════════════════════════════════════════════╗
-- ║   Unity加速器 - 在线加载器                    ║
-- ║   优先云端拉取，失败用本地内置                  ║
-- ║   署名: xy435116694754                      ║
-- ╚══════════════════════════════════════════════╝
-- ============================================================

local AUTHOR = "xy435116694754"
local APP_NAME = "Unity加速器"
local LOCAL_VER = "v4.4"  -- 内置脚本版本号

-- ====== 远程脚本地址列表（按优先级） ======
local SCRIPT_URLS = {
    "https://www.coze.cn/s/0US4k-VeMHE/",
}

-- ====== 尝试云端加载 ======
function tryCloudLoad()
    for i, url in ipairs(SCRIPT_URLS) do
        gg.toast("☁️ 尝试云端源 " .. i .. "/" .. #SCRIPT_URLS .. " ...")
        local ok, response = pcall(function()
            return gg.makeRequest(url)
        end)
        if ok and response and response ~= "" then
            -- 检查是否是有效Lua脚本
            if string.find(response, "Unity") and string.find(response, "timeScale") then
                local func, err = loadstring(response)
                if func then
                    -- 提取版本号
                    local ver = string.match(response, "APP_VER%s*=%s*\"([^\"]+)\"") or "未知"
                    gg.toast("✅ 云端 " .. ver .. " 加载成功！")
                    return func
                end
            end
        end
    end
    return nil
end

-- ====== 本地内置脚本（云端加载失败时使用） ======
-- 此处嵌入完整主脚本，确保离线也能用
-- 注意：更新此部分需同时更新 LOCAL_VER

function runLocal()
    -- 执行本地文件（同目录下的 speed_hack.lua）
    local localPath = gg.getFile():match("(.*[/\\])") .. "speed_hack.lua"
    local f = io.open(localPath, "r")
    if f then
        local content = f:read("*a")
        f:close()
        local func, err = loadstring(content)
        if func then
            gg.toast("📁 本地 " .. LOCAL_VER .. " 加载成功")
            func()
            return true
        end
    end
    return false
end

-- ====== 主逻辑 ======
gg.toast("⚡ " .. APP_NAME .. " 启动中...")

-- 先尝试云端
local cloudFunc = tryCloudLoad()

if cloudFunc then
    cloudFunc()
else
    -- 云端失败，尝试本地
    gg.toast("☁️ 云端不可用，切换本地...")
    local localOk = runLocal()

    if not localOk then
        -- 本地也没有，提示
        local choice = gg.choice(
            {"🔄  重试云端", "❌  退出"},
            nil,
            "⚠️ 加载失败\n\n" ..
            "云端: 不可用\n" ..
            "本地: 未找到 speed_hack.lua\n\n" ..
            "请确保：\n" ..
            "① 网络连接正常\n" ..
            "② 或将主脚本放在同目录下"
        )
        if choice == 1 then
            local retry = tryCloudLoad()
            if retry then
                retry()
            else
                gg.alert("❌ 重试失败")
            end
        end
    end
end
