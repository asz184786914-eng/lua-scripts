-- GG文件读写测试（无os.execute版）
local results = {}

-- io.open读测试
local paths = {
    "/sdcard/.unity_key",
    "/data/local/tmp/.unity_key",
}

for _, p in ipairs(paths) do
    local f = io.open(p, "r")
    if f then
        local d = f:read("*a")
        f:close()
        results[#results + 1] = "✅ 读 " .. p .. " → [" .. (d or "nil") .. "]"
    else
        results[#results + 1] = "❌ 读 " .. p .. " → 打不开"
    end
end

-- io.open写+读回测试 /sdcard
local wf = io.open("/sdcard/.unity_key_writetest", "w")
if wf then
    wf:write("WRITE_TEST_123")
    wf:close()
    local rf = io.open("/sdcard/.unity_key_writetest", "r")
    if rf then
        local rd = rf:read("*a")
        rf:close()
        if rd == "WRITE_TEST_123" then
            results[#results + 1] = "✅ io写读/sdcard → 一致"
        else
            results[#results + 1] = "⚠️ io写读/sdcard → 不匹配[" .. (rd or "nil") .. "]"
        end
    else
        results[#results + 1] = "❌ io写读/sdcard → 写了读不回"
    end
else
    results[#results + 1] = "❌ io写/sdcard → 失败"
end

-- io.open写+读回测试 /data/local/tmp
local wf2 = io.open("/data/local/tmp/.unity_key_writetest", "w")
if wf2 then
    wf2:write("WRITE_TEST_TMP")
    wf2:close()
    local rf2 = io.open("/data/local/tmp/.unity_key_writetest", "r")
    if rf2 then
        local rd2 = rf2:read("*a")
        rf2:close()
        if rd2 == "WRITE_TEST_TMP" then
            results[#results + 1] = "✅ io写读/tmp → 一致"
        else
            results[#results + 1] = "⚠️ io写读/tmp → 不匹配[" .. (rd2 or "nil") .. "]"
        end
    else
        results[#results + 1] = "❌ io写读/tmp → 写了读不回"
    end
else
    results[#results + 1] = "❌ io写/tmp → 失败"
end

-- gg.saveVariable + gg.loadVariable
if type(gg.saveVariable) == "function" then
    pcall(gg.saveVariable, "test_key", "SAVE_VAR_123")
else
    results[#results + 1] = "❌ gg.saveVariable → 不存在"
end
if type(gg.loadVariable) == "function" then
    local ok2, v2 = pcall(gg.loadVariable, "test_key")
    if ok2 and v2 == "SAVE_VAR_123" then
        results[#results + 1] = "✅ gg.save/loadVariable → 一致"
    else
        results[#results + 1] = "❌ gg.save/loadVariable → 不一致[" .. tostring(v2) .. "]"
    end
else
    results[#results + 1] = "❌ gg.loadVariable → 不存在"
end

-- gg.getFile 测试
local ok3, sp = pcall(gg.getFile)
if ok3 and sp then
    results[#results + 1] = "📂 gg.getFile → " .. sp
else
    results[#results + 1] = "❌ gg.getFile → 失败"
end

gg.alert(table.concat(results, "\n"))
